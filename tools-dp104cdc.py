#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
#
# dp104status — agent activity on a Ticktype DP104 keyboard screen
# Copyright (C) 2026 Shule Zhao
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the
# Free Software Foundation, version 3.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program. If not, see <https://www.gnu.org/licenses/>.

"""TICKTYPE DP-104 ("EVO 104") — push a CUSTOM frame to the 8x24 screen over USB CDC.

The screen data channel is NOT raw HID: the DP-104 firmware answers 0xff
("unknown command") to the HID 0xD1 block-transfer commands.  VIA falls back to
TabKeyboardAPI, which speaks a 64-byte fixed-size packet protocol over the
keyboard's USB CDC serial interface.

  packet   : [cmd, *args] zero-padded to 64 bytes, 115200 8N1, no checksum
  response : 64 bytes, resp[1:] echoes the args
  0xC0     : header [frames, fps, rows, cols]; resp[5]==0xEE means error,
             resp[6] says whether data chunks are acknowledged
  0xC1     : data   [offset(4, big-endian), len, *payload]  (56 bytes/chunk)
  payload  : 3 bytes per pixel, HSV each scaled to 0-255 (get256HSV), ordered
             frame-major -> row-major -> column
"""
import colorsys, os, sys, termios

PORT = sys.argv[1] if len(sys.argv) > 1 else "/dev/cu.usbmodem214304"
BUFFER_SIZE = 64
CHUNK = BUFFER_SIZE - 8          # 56
ROWS, COLS = 8, 24               # /tabkb/configs.json -> "EVO 104".matrixLighting


def open_port(path):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    _, _, _, _, _, _, cc = termios.tcgetattr(fd)
    cc[termios.VMIN], cc[termios.VTIME] = 0, 10          # 1.0s read timeout
    termios.tcsetattr(fd, termios.TCSANOW, [
        0,                                                # iflag: raw
        0,                                                # oflag: raw
        termios.CS8 | termios.CREAD | termios.CLOCAL,     # cflag: 8N1, no flow ctl
        0,                                                # lflag: non-canonical
        termios.B115200, termios.B115200, cc])
    os.set_blocking(fd, True)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def packet(fd, cmd, args=(), want_response=True):
    buf = bytearray(BUFFER_SIZE)
    buf[0] = cmd
    buf[1:1 + len(args)] = bytes(args)
    os.write(fd, bytes(buf))
    if not want_response:
        return None
    got = b""
    while len(got) < BUFFER_SIZE:
        part = os.read(fd, BUFFER_SIZE - len(got))
        if not part:
            break
        got += part
    return got


def hsv256(r, g, b):
    h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
    return [round(255 * h), round(255 * s), round(255 * v)]


def main():
    if not os.path.exists(PORT):
        sys.exit(f"no such serial port: {PORT}")
    fd = open_port(PORT)
    print(f"port    : {PORT} @115200")

    pattern = os.environ.get("PATTERN", "bands")
    blue, orange, green = hsv256(0, 0, 255), hsv256(255, 132, 0), hsv256(0, 255, 0)
    red, white, off = hsv256(255, 0, 0), hsv256(255, 255, 255), [0, 0, 0]

    frame = bytearray()
    for row in range(ROWS):
        for col in range(COLS):
            if pattern == "bands":          # 3 vertical bands
                px = blue if col < 8 else orange if col < 16 else green
            elif pattern == "halves":       # top red / bottom white — unmistakably different
                px = red if row < 4 else white
            else:                           # checker
                px = white if (row // 2 + col // 3) % 2 == 0 else off
            frame += bytes(px)
    print(f"pattern : {pattern}")
    print(f"frame   : {ROWS}x{COLS} = {len(frame)} bytes")

    hdr = packet(fd, 0xC0, [1, 10, ROWS, COLS])
    print(f"header  : {hdr[:10].hex(' ') if hdr else '<no response>'}")
    if not hdr:
        sys.exit("no response to 0xC0 — wrong port?")
    if hdr[5] == 0xEE:
        sys.exit(f"device rejected header (resp[5]=0xEE)")
    ack = bool(hdr[6])
    print(f"          resp[5]=0x{hdr[5]:02x} resp[6]={hdr[6]} -> chunks {'acked' if ack else 'fire-and-forget'}")

    n_chunks = 0
    for off in range(0, len(frame), CHUNK):
        part = frame[off:off + CHUNK]
        args = list(off.to_bytes(4, "big")) + [len(part)] + list(part)
        r = packet(fd, 0xC1, args, want_response=ack)
        if ack and r and r[5] == 0xEE:
            sys.exit(f"chunk @{off} rejected")
        n_chunks += 1
    print(f"data    : {len(frame)} bytes in {n_chunks} chunks -> OK")
    print("\nuploaded — check the screen (CUSTOM mode)")
    os.close(fd)


if __name__ == "__main__":
    main()
