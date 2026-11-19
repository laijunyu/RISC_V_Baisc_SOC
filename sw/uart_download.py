#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
XT_RV32I UART 下载脚本
不需要 pyserial，直接用 ctypes 调 Win32 串口 API

协议 (从 BOOT ROM 反汇编还原):
    'V'(0x56) -> 块数(2字节大端) -> 'x'(0x78) -> 数据(块数*16 字节)
    芯片把数据直接写进 RAM[0..]

用法:
    python uart_download.py                    # 自动选唯一的串口
    python uart_download.py -p COM6 -f blink.bin
"""

import ctypes
import sys
import time
import argparse
from ctypes import wintypes

if sys.platform != "win32":
    sys.exit("本脚本只支持 Windows")

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

k32 = ctypes.WinDLL("kernel32", use_last_error=True)


class DCB(ctypes.Structure):
    _fields_ = [
        ("DCBlength", wintypes.DWORD),
        ("BaudRate", wintypes.DWORD),
        ("flags", wintypes.DWORD),
        ("wReserved", wintypes.WORD),
        ("XonLim", wintypes.WORD),
        ("XoffLim", wintypes.WORD),
        ("ByteSize", wintypes.BYTE),
        ("Parity", wintypes.BYTE),
        ("StopBits", wintypes.BYTE),
        ("XonChar", wintypes.BYTE),
        ("XoffChar", wintypes.BYTE),
        ("ErrorChar", wintypes.BYTE),
        ("EofChar", wintypes.BYTE),
        ("EvtChar", wintypes.BYTE),
        ("wReserved1", wintypes.WORD),
    ]


k32.CreateFileW.restype = wintypes.HANDLE
k32.CreateFileW.argtypes = [
    wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
    ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p,
]
k32.BuildCommDCBW.argtypes = [wintypes.LPCWSTR, ctypes.POINTER(DCB)]
k32.SetCommState.argtypes = [wintypes.HANDLE, ctypes.POINTER(DCB)]
k32.WriteFile.argtypes = [
    wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
    ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p,
]

INVALID_HANDLE = ctypes.c_void_p(-1).value
GENERIC_WRITE = 0x40000000
OPEN_EXISTING = 3


def list_ports():
    """从注册表读当前存在的串口"""
    import winreg
    out = []
    try:
        key = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE,
                             r"HARDWARE\DEVICEMAP\SERIALCOMM")
        i = 0
        while True:
            try:
                name, val, _ = winreg.EnumValue(key, i)
                i += 1
                out.append((val, name))
            except OSError:
                break
    except OSError:
        pass
    return out


def open_port(port, baud):
    h = k32.CreateFileW("\\\\.\\" + port, GENERIC_WRITE, 0,
                        None, OPEN_EXISTING, 0, None)
    if h is None or h == INVALID_HANDLE:
        err = ctypes.get_last_error()
        raise OSError(err, f"打开 {port} 失败 (错误码 {err})，"
                           f"检查是否被串口助手占用")

    dcb = DCB()
    dcb.DCBlength = ctypes.sizeof(DCB)
    spec = f"baud={baud} parity=N data=8 stop=1"
    if not k32.BuildCommDCBW(spec, ctypes.byref(dcb)):
        err = ctypes.get_last_error()
        raise OSError(err, f"BuildCommDCB 失败 (错误码 {err})")
    if not k32.SetCommState(h, ctypes.byref(dcb)):
        err = ctypes.get_last_error()
        raise OSError(err, f"SetCommState 失败 (错误码 {err})，波特率 {baud} 可能不支持")
    return h


def send(h, data):
    n = wintypes.DWORD(0)
    buf = ctypes.create_string_buffer(bytes(data), len(data))
    if not k32.WriteFile(h, buf, len(data), ctypes.byref(n), None):
        err = ctypes.get_last_error()
        raise OSError(err, f"WriteFile 失败 (错误码 {err})")
    return n.value


def main():
    ap = argparse.ArgumentParser(description="XT_RV32I UART 下载")
    ap.add_argument("-p", "--port", help="串口号，如 COM6；不填则自动选")
    ap.add_argument("-f", "--file", default="blink.bin", help="要下载的 bin 文件")
    ap.add_argument("--baud", type=int, default=19200)
    args = ap.parse_args()

    ports = list_ports()
    if ports:
        print("当前串口:")
        for val, name in ports:
            print(f"  {val:8s}  {name}")
    else:
        print("没有检测到串口")

    if not args.port:
        if len(ports) == 1:
            args.port = ports[0][0]
            print(f"\n自动选择 {args.port}")
        else:
            sys.exit("\n请用 -p 指定串口，例如: -p COM6")

    with open(args.file, "rb") as f:
        data = f.read()

    blk = 16
    blocks = (len(data) + blk - 1) // blk
    if blocks > 480:
        sys.exit(f"程序 {len(data)} 字节，超过上限 {blk * 480}")
    padded = data + b"\x00" * (blocks * blk - len(data))

    print(f"\n端口 {args.port}  波特率 {args.baud}")
    print(f"文件 {args.file}  {len(data)} 字节 -> {blocks} 块 / {len(padded)} 字节\n")

    h = open_port(args.port, args.baud)
    try:
        time.sleep(0.3)
        send(h, b"V")
        send(h, bytes([(blocks >> 8) & 0xFF, blocks & 0xFF]))
        time.sleep(0.05)
        send(h, b"x")
        # 芯片收到 'x' 后有约 300ms 准备延时，等它过去再发数据
        time.sleep(0.4)
        send(h, padded)
        print("数据已发送")
    finally:
        time.sleep(0.6)
        k32.CloseHandle(h)

    print()
    print("=" * 46)
    print(" 下载完成")
    print("=" * 46)
    print(" 1. 先松开 K1")
    print(" 2. 再复位 SoC")
    print()
    print(" 顺序反了会重新进下载模式")


if __name__ == "__main__":
    try:
        main()
    except OSError as e:
        print(f"\n[错误] {e}")
        sys.exit(1)
    except KeyboardInterrupt:
        print("\n已中断")
        sys.exit(1)
