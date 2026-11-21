#!/usr/bin/env python3
"""Adapt the fetched SukiSU-Ultra sources to this Linux 4.19 tree.

SukiSU-Ultra targets recent kernels and its sources are pulled from a moving
branch at build time, so a few places do not compile on 4.19:

  1. extension/kpm/kpm.c calls access_ok() with two arguments.  The type
     argument was only dropped in 5.0, and 4.19 still needs it.  The call
     guards a copy_to_user() target, so it has to be VERIFY_WRITE.

  2. selinux/sepolicy.c re-declares susfs_add_sus_avd_allowed_by_type() with
     an outdated signature (u16 third argument).  This tree's linux/susfs.h
     already declares it with u32, so the local copy both conflicts and is
     redundant.

  3. selinux/rules.c declares "struct selinux_policy *pol, *old_pol" outside
     the LINUX_VERSION_CODE >= 5.10 block that is the only user, so 4.19
     builds warn about unused variables and fail on -Werror.

Every edit is idempotent and reported.  If a pattern is not found the script
warns and moves on: the source may have been fixed upstream, and the compile
step stays the authority on whether the tree is good.

Usage: sukisu_419_fixup.py <path to drivers/kernelsu>
"""

import os
import sys

# access_ok() lost its first argument in 5.0; before that the direction is
# part of the check.  The kpm buffer is written by the following copy_to_user.
ACCESS_OK_OLD = (
    "    if (!access_ok(u64_to_user_ptr(cmd.result_code), sizeof(result))) "
    "return -EFAULT;"
)
ACCESS_OK_NEW = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)
    if (!access_ok(u64_to_user_ptr(cmd.result_code), sizeof(result))) return -EFAULT;
#else
    if (!access_ok(VERIFY_WRITE, u64_to_user_ptr(cmd.result_code), sizeof(result))) return -EFAULT;
#endif"""

STALE_AVD_EXTERN = (
    "extern int susfs_add_sus_avd_allowed_by_type(u32 s_type, u32 t_type, "
    "u16 type, u32 orig_avd_allowed);\n"
)

RULES_DECL = "    struct selinux_policy *pol, *old_pol;\n"
RULES_DECL_GUARDED = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
    struct selinux_policy *pol, *old_pol;
#endif
"""


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
        text = text.replace(old, "", 1)
        write(path, text)
        print("  [patched] %s" % label)
        return

    if new in text:
        print("  [already applied] %s" % label)
        return
    if old not in text:
        print("  [pattern not found] %s" % label)
        return
    text = text.replace(old, new, 1)
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
        ACCESS_OK_OLD,
        ACCESS_OK_NEW,
        "kpm: access_ok() direction argument",
    )

    apply_edit(
        os.path.join(root, "selinux", "sepolicy.c"),
        STALE_AVD_EXTERN,
        None,
        "sepolicy: drop stale susfs_add_sus_avd_allowed_by_type prototype",
    )

    # Only the first declaration is outside a 5.10 guard; the second one in
    # handle_sepolicy() already sits inside "#if LINUX_VERSION_CODE >= 5.10".
    apply_edit(
        os.path.join(root, "selinux", "rules.c"),
        RULES_DECL,
        RULES_DECL_GUARDED,
        "rules: pol/old_pol declaration guard",
    )

    print("[+] 4.19 compatibility fixups done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
