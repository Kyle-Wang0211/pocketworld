#!/usr/bin/env python3
"""16 KB page-size check for ELF shared objects, with no Android SDK.

WHY THIS EXISTS
    Google's documented acceptance test is

        zipalign -c -P 16 -v 4 APK_NAME.apk

    which checks how the .so files are POSITIONED inside the zip. It does NOT
    check how they are built. A library whose PT_LOAD segments are aligned to
    0x1000 passes zipalign and still cannot be mapped on a 16 KB device.
    Both properties have to hold, and they fail independently:

        segment alignment  <- the NDK that compiled the .so   (NDK r28+)
        zip alignment      <- the AGP that packaged the APK   (AGP 8.5.1+)

    The second is only checkable with the Android build-tools installed. The
    first is checkable anywhere, including on a machine with no Android SDK,
    which is exactly the situation a prebuilt dependency audit is in: xrslam's
    libxrslam.so, OpenCV's libopencv_java*.so and every Flutter plugin's .so
    are prebuilt artefacts that must each be checked on their own.

    Reads only the ELF header and the program-header table -- a few hundred
    bytes -- so it is safe to point at a directory of large libraries.

EXIT CODES
    0  every file checked has all PT_LOAD segments aligned to >= 16384
    1  at least one file fails
    2  usage / unreadable input
"""

import os
import struct
import sys

PT_LOAD = 1
REQUIRED_ALIGN = 16 * 1024

EM = {3: "x86", 40: "arm", 62: "x86_64", 183: "aarch64", 243: "riscv"}


class NotAnElf(Exception):
    pass


def load_segment_aligns(path):
    """Return (machine, is64, [p_align, ...]) for PT_LOAD segments."""
    with open(path, "rb") as f:
        ident = f.read(16)
        if len(ident) < 16 or ident[:4] != b"\x7fELF":
            raise NotAnElf("not an ELF file")
        ei_class, ei_data = ident[4], ident[5]
        if ei_class not in (1, 2):
            raise NotAnElf("bad EI_CLASS %d" % ei_class)
        endian = "<" if ei_data == 1 else ">"
        is64 = ei_class == 2

        f.seek(0)
        head = f.read(64 if is64 else 52)
        if is64:
            # e_type, e_machine, e_version, e_entry, e_phoff, e_shoff, e_flags,
            # e_ehsize, e_phentsize, e_phnum
            (machine,) = struct.unpack_from(endian + "H", head, 18)
            (phoff,) = struct.unpack_from(endian + "Q", head, 32)
            (phentsize,) = struct.unpack_from(endian + "H", head, 54)
            (phnum,) = struct.unpack_from(endian + "H", head, 56)
            phfmt = endian + "IIQQQQQQ"  # type flags offset vaddr paddr filesz memsz align
            align_index = 7
        else:
            (machine,) = struct.unpack_from(endian + "H", head, 18)
            (phoff,) = struct.unpack_from(endian + "I", head, 28)
            (phentsize,) = struct.unpack_from(endian + "H", head, 42)
            (phnum,) = struct.unpack_from(endian + "H", head, 44)
            phfmt = endian + "IIIIIIII"  # type offset vaddr paddr filesz memsz flags align
            align_index = 7

        want = struct.calcsize(phfmt)
        if phentsize < want:
            raise NotAnElf("e_phentsize %d < %d" % (phentsize, want))

        aligns = []
        f.seek(phoff)
        for _ in range(phnum):
            raw = f.read(phentsize)
            if len(raw) < want:
                break
            fields = struct.unpack_from(phfmt, raw, 0)
            if fields[0] == PT_LOAD:
                aligns.append(fields[align_index])
        return machine, is64, aligns


def gather(paths):
    files = []
    for p in paths:
        if os.path.isdir(p):
            for root, _dirs, names in os.walk(p):
                for n in sorted(names):
                    if n.endswith(".so"):
                        files.append(os.path.join(root, n))
        else:
            files.append(p)
    return files


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(
            "usage: check_elf_align.py <file.so|dir> [...]\n"
            "       checks every PT_LOAD segment is aligned to >= 16384\n")
        return 2

    files = gather(argv[1:])
    if not files:
        sys.stderr.write("no .so files found in: %s\n" % " ".join(argv[1:]))
        return 2

    failures = 0
    skipped = 0
    for path in files:
        try:
            machine, is64, aligns = load_segment_aligns(path)
        except NotAnElf as e:
            print("SKIP  %-9s %s  (%s)" % ("", path, e))
            skipped += 1
            continue
        except OSError as e:
            print("SKIP  %-9s %s  (%s)" % ("", path, e))
            skipped += 1
            continue

        arch = EM.get(machine, "machine=%d" % machine)
        if not aligns:
            print("FAIL  %-9s %s  (no PT_LOAD segments)" % (arch, path))
            failures += 1
            continue

        worst = min(aligns)
        ok = worst >= REQUIRED_ALIGN
        # A 32-bit ABI is not subject to the 16 KB requirement, but it is also
        # not something this project ships; report it rather than pass it.
        note = "" if is64 else "  [32-bit ABI]"
        print("%s  %-9s %s  min PT_LOAD align=0x%x (%d KB) over %d segments%s"
              % ("PASS" if ok else "FAIL", arch, path, worst,
                 worst // 1024, len(aligns), note))
        if not ok:
            failures += 1

    print("---- %d checked, %d failed, %d skipped" %
          (len(files) - skipped, failures, skipped))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
