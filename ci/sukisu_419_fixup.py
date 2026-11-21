#!/usr/bin/env python3
"""Adapt the fetched SukiSU-Ultra sources to this Linux 4.19 tree.

SukiSU-Ultra targets recent kernels and its sources are pulled from a moving
branch at build time, so several places do not build (or would not run) on
4.19.  Every edit below is idempotent, reported, and skipped with a warning
when its anchor is gone -- an upstream fix must not turn into a build break.

  1. extension/kpm/kpm.c
     access_ok() only lost its direction argument in 5.0.  The guarded address
     is written by the following copy_to_user(), so the 4.19 branch needs
     VERIFY_WRITE (the tree's own ksu_access_ok() maps to VERIFY_READ and would
     check the wrong direction).

  2. selinux/sepolicy.c
     A local prototype of susfs_add_sus_avd_allowed_by_type() still carries the
     older u16 third parameter, while this tree's linux/susfs.h declares u32.
     That header is already visible here, so the local copy is redundant.

  3. selinux/rules.c
     "struct selinux_policy *pol, *old_pol" sits outside the
     LINUX_VERSION_CODE >= 5.10 block that is their only user, so 4.19 trips
     -Wunused-variable under -Werror.

  4. kernel_includes.h
     The TWA_* enum arrived in 5.9; on 4.19 task_work_add() takes a plain bool.
     One define here covers all four call sites (the sources are amalgamated
     into ksu_main.c, which includes this header first).

  5. infra/su_mount_ns.c
     path_mount() came with the 5.2 mount API refactor.  The only call site
     wants MS_PRIVATE|MS_REC on the fs root, which ksys_mount() can do; on
     4.19 it is reached through set_fs(KERNEL_DS) so kernel strings are taken
     as user pointers (that trick works up to 5.10).

  6. extension/cpu_spoof.c
     struct clocksource.vdso_clock_mode and enum vdso_clock_mode are 5.3+.

Usage: sukisu_419_fixup.py <path to drivers/kernelsu>
"""

import os
import sys

# --- 1. kpm: access_ok direction -------------------------------------------
ACCESS_OK_OLD = (
    "    if (!access_ok(u64_to_user_ptr(cmd.result_code), sizeof(result))) "
    "return -EFAULT;"
)
ACCESS_OK_NEW = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)
    if (!access_ok(u64_to_user_ptr(cmd.result_code), sizeof(result))) return -EFAULT;
#else
    if (!access_ok(VERIFY_WRITE, u64_to_user_ptr(cmd.result_code), sizeof(result))) return -EFAULT;
#endif"""

# --- 2. sepolicy: stale susfs prototype ------------------------------------
STALE_AVD_EXTERN = (
    "extern int susfs_add_sus_avd_allowed_by_type(u32 s_type, u32 t_type, "
    "u16 type, u32 orig_avd_allowed);\n"
)

# --- 3. rules: unused selinux_policy pointers ------------------------------
RULES_DECL = "    struct selinux_policy *pol, *old_pol;\n"
RULES_DECL_GUARDED = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
    struct selinux_policy *pol, *old_pol;
#endif
"""

# --- 4. kernel_includes: TWA_RESUME ---------------------------------------
TWA_OLD = "#include <linux/task_work.h>\n"
TWA_NEW = """#include <linux/task_work.h>
/* 4.19 task_work_add() takes a bool; the TWA_* enum only appeared in 5.9. */
#ifndef TWA_RESUME
#define TWA_RESUME true
#endif
"""

# --- 5. su_mount_ns: path_mount on 4.19 ------------------------------------
PATH_MOUNT_OLD = """extern int path_mount(const char *dev_name, struct path *path, const char *type_page, unsigned long flags,
                      void *data_page);
"""
PATH_MOUNT_NEW = """/*
 * path_mount() only exists from 5.2.  The single call site asks for
 * MS_PRIVATE | MS_REC on the fs root, which ksys_mount() can do; on 4.19 it is
 * reached through set_fs(KERNEL_DS) so the kernel strings are accepted as user
 * pointers, a trick that keeps working up to 5.10.
 */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 2, 0)
extern int path_mount(const char *dev_name, struct path *path, const char *type_page, unsigned long flags,
                      void *data_page);
#else
#include <linux/syscalls.h>
#include <linux/uaccess.h>
static int path_mount(const char *dev_name, struct path *path, const char *type_page,
                      unsigned long flags, void *data_page)
{
    mm_segment_t old_fs;
    int ret;

    (void)dev_name;
    (void)path;
    (void)type_page;
    (void)data_page;

    old_fs = get_fs();
    set_fs(KERNEL_DS);
    ret = ksys_mount(NULL, (char __user *)"/", NULL, flags, NULL);
    set_fs(old_fs);
    return ret;
}
#endif
"""

# --- 6. cpu_spoof: vdso_clock_mode -----------------------------------------
CPU_SPOOF_MARKER = "/* 4.19: struct clocksource.vdso_clock_mode is 5.3+ */"
CPU_SPOOF_GUARD_OPEN = (
    CPU_SPOOF_MARKER + "\n#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 3, 0)\n"
)
CPU_SPOOF_GUARD_CLOSE = "#endif /* >= 5.3 */\n"
CPU_SPOOF_BLOCK1 = "struct clocksource **curr_cs_ptr ="
CPU_SPOOF_BLOCK2 = "enum vdso_clock_mode *vd_default ="
CPU_SPOOF_BLOCK_END = "                        ++missing;\n                    }\n                }\n"


def read(path):
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        return f.read()


def write(path, text):
    with open(path, "w", encoding="utf-8", errors="surrogateescape", newline="") as f:
        f.write(text)


def apply_edit(path, old, new, label):
    """Replace old with new once, or delete old when new is None."""
    if not os.path.isfile(path):
        print("  [skip] %s: %s missing" % (label, path))
        return
    text = read(path)

    if new is None:
        if old not in text:
            print("  [already applied] %s" % label)
            return
        write(path, text.replace(old, "", 1))
        print("  [patched] %s" % label)
        return

    if new in text:
        print("  [already applied] %s" % label)
        return
    if old not in text:
        print("  [pattern not found] %s" % label)
        return
    write(path, text.replace(old, new, 1))
    print("  [patched] %s" % label)


def guard_cpu_spoof(path):
    label = "cpu_spoof: guard vdso_clock_mode accessors"
    if not os.path.isfile(path):
        print("  [skip] %s: %s missing" % (label, path))
        return
    text = read(path)
    if CPU_SPOOF_MARKER in text:
        print("  [already applied] %s" % label)
        return

    first = text.find(CPU_SPOOF_BLOCK1)
    second = text.find(CPU_SPOOF_BLOCK2)
    if first < 0 or second < 0:
        print("  [pattern not found] %s" % label)
        return

    # The guard opens on the "{" line that starts the first block.
    brace = text.rfind("                {\n", 0, first)
    if brace < 0:
        print("  [pattern not found] %s" % label)
        return

    # The guard closes right after the second block's closing brace.
    tail = text.find(CPU_SPOOF_BLOCK_END, second)
    if tail < 0:
        print("  [pattern not found] %s" % label)
        return
    tail_end = tail + len(CPU_SPOOF_BLOCK_END)

    text = (
        text[:brace]
        + CPU_SPOOF_GUARD_OPEN
        + text[brace:tail_end]
        + CPU_SPOOF_GUARD_CLOSE
        + text[tail_end:]
    )
    write(path, text)
    print("  [patched] %s" % label)


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2

    root = sys.argv[1]
    if not os.path.isdir(root):
        print("  [skip] %s does not exist, nothing to fix up" % root)
        return 0

    print("[*] Applying 4.19 compatibility fixups to %s" % root)

    apply_edit(
        os.path.join(root, "extension", "kpm", "kpm.c"),
        ACCESS_OK_OLD, ACCESS_OK_NEW,
        "kpm: access_ok() direction argument",
    )
    apply_edit(
        os.path.join(root, "selinux", "sepolicy.c"),
        STALE_AVD_EXTERN, None,
        "sepolicy: drop stale susfs_add_sus_avd_allowed_by_type prototype",
    )
    apply_edit(
        os.path.join(root, "selinux", "rules.c"),
        RULES_DECL, RULES_DECL_GUARDED,
        "rules: pol/old_pol declaration guard",
    )
    apply_edit(
        os.path.join(root, "kernel_includes.h"),
        TWA_OLD, TWA_NEW,
        "kernel_includes: TWA_RESUME for 4.19 task_work_add()",
    )
    apply_edit(
        os.path.join(root, "infra", "su_mount_ns.c"),
        PATH_MOUNT_OLD, PATH_MOUNT_NEW,
        "su_mount_ns: path_mount() shim via ksys_mount()",
    )
    guard_cpu_spoof(os.path.join(root, "extension", "cpu_spoof.c"))

    print("[+] 4.19 compatibility fixups done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
