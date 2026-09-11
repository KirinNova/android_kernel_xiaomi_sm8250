#!/bin/bash

# Some logics of this script are copied from [scripts/build_kernel]. Thanks to UtsavBalar1231.
#
# SELinux hide / manager v3-v4 compat are applied AFTER SukiSU-Ultra setup.sh
# builtin. Do not touch apply_kernelsu_rules() or other boot-critical SELinux
# update paths: a deep-copy there caused first-logo reboot loops on SM8250 4.19.

# Exit on command or pipeline failures. This is important for remote setup/patch
# downloads: a failed curl must never be hidden by the command behind the pipe.
set -eo pipefail

# ==========================================
# Argument Parsing
# ==========================================
if [ -z "$1" ]; then
    echo "[!] Error: No device specified."
    echo "Usage: $0 <device_name> [ksu] [miui|aosp] [hide|nohide]"
    echo "Example: $0 lmi"
    echo "         $0 lmi ksu"
    echo "         $0 lmi ksu miui"
    echo "         $0 lmi aosp"
    echo "         $0 lmi ksu hide"
    exit 1
fi

DEVICE_NAME="$1"
DEFCONFIG="${DEVICE_NAME}_defconfig"
DEFCONFIG_PATH="arch/arm64/configs/${DEFCONFIG}"

if [ ! -f "$DEFCONFIG_PATH" ]; then
    echo "[!] Error: Defconfig not found at $DEFCONFIG_PATH"
    echo "[!] Please verify the device name and try again."
    exit 1
fi

ENABLE_KSU=0
ENABLE_SELINUX_HIDE=1
TARGET_OS="both"

shift
# Parse remaining arguments loosely
for arg in "$@"; do
    case "$arg" in
        ksu) ENABLE_KSU=1 ;;
        miui) TARGET_OS="miui" ;;
        aosp) TARGET_OS="aosp" ;;
        hide) ENABLE_SELINUX_HIDE=1 ;;
        nohide) ENABLE_SELINUX_HIDE=0 ;;
    esac
done

# ==========================================
# Configuration & Environment
# ==========================================
KERNEL_DIR="$(pwd)"
TOOLCHAIN_BIN="$HOME/zyc-clang/bin"

export PATH="${TOOLCHAIN_BIN}:${PATH}"
export ARCH="arm64"
export SUBARCH="arm64"

# ccache Setup
export CCACHE_DIR="$HOME/.cache/ccache_mikernel"
export CCACHE_EXEC=$(command -v ccache)

if [ -z "$CCACHE_EXEC" ]; then
    echo "[!] ccache not found! Please install ccache first."
    exit 1
fi

export USE_CCACHE=1
export CROSS_COMPILE="aarch64-linux-gnu-"
export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"

echo "[*] Checking Clang version..."
clang --version || { echo "[!] Clang not found at ${TOOLCHAIN_BIN}. Please check the path."; exit 1; }

echo "[*] Setting up ccache in $CCACHE_DIR..."
mkdir -p "$CCACHE_DIR"

# Keep SukiSU-Ultra as the KSU implementation. Hide donor is ReSukiSU only.
KSU_SETUP_URL="${KSU_SETUP_URL:-https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh}"
KSU_HIDE_DONOR_URL="${KSU_HIDE_DONOR_URL:-https://github.com/ReSukiSU/ReSukiSU.git}"

# ==========================================
# Droidspaces Constants & Functions
# ==========================================
DROIDSPACES_VERSION="${DROIDSPACES_VERSION:-v6.4.5}"
DROIDSPACES_PATCH_BASE="https://raw.githubusercontent.com/ravindu644/Droidspaces-OSS/${DROIDSPACES_VERSION}/Documentation/resources/kernel-patches/non-GKI"
DROIDSPACES_XT_QTAGUID_SHA256="f71898942e0f872c5cf28ebaef0dcd9b9efe7e02f0dfc8310441efa8772fed7d"
DROIDSPACES_CGROUP_SHA256="6d2c9dbe5aa394328c35845e416ac274bade7dce36994b945de75769448219cc"

apply_droidspaces_patch() {
    local description="$1"
    local url="$2"
    local expected_sha256="$3"
    local patch_file="$4"

    echo "Download Droidspaces patch: ${description}"
    curl -fLSs --retry 3 --connect-timeout 20 -o "$patch_file" "$url"
    printf '%s  %s\n' "$expected_sha256" "$patch_file" | sha256sum -c -

    if git apply --check --whitespace=nowarn "$patch_file" 2>/dev/null; then
        git apply --whitespace=nowarn "$patch_file"
        echo "Applied Droidspaces patch: ${description}"
    elif git apply --reverse --check --whitespace=nowarn "$patch_file" 2>/dev/null; then
        echo "Droidspaces patch already applied: ${description}"
    else
        git apply --check --whitespace=nowarn "$patch_file" || true
        echo "ERROR: Droidspaces patch is incompatible with this kernel tree: ${description}"
        echo "Do not continue building a kernel that only passes config checks; this patch prevents a runtime kernel panic."
        exit 1
    fi
}

integrate_droidspaces_non_gki() {
    local kernel_version kernel_patchlevel kernel_series patch_dir

    kernel_version=$(awk '$1 == "VERSION" { print $3; exit }' Makefile)
    kernel_patchlevel=$(awk '$1 == "PATCHLEVEL" { print $3; exit }' Makefile)
    kernel_series="${kernel_version}.${kernel_patchlevel}"

    case "$kernel_series" in
        3.18|4.4|4.9|4.14|4.19)
            ;;
        *)
            echo "ERROR: Detected Linux ${kernel_series}. This script carries Droidspaces non-GKI patches only."
            echo "For a GKI kernel, use the version-specific kABI patches from the official Droidspaces guide."
            exit 1
            ;;
    esac

    if [ ! -f kernel/cgroup/cgroup.c ]; then
        echo "ERROR: This legacy kernel tree lacks kernel/cgroup/cgroup.c."
        exit 1
    fi

    patch_dir=$(mktemp -d /tmp/droidspaces-kernel-patches.XXXXXX)

    if [ -f net/netfilter/xt_qtaguid.c ]; then
        apply_droidspaces_patch \
            "avoid xt_qtaguid kernel panic when container interfaces change" \
            "${DROIDSPACES_PATCH_BASE}/01.fix_kernel_panic_in_xt_qtaguid.patch" \
            "$DROIDSPACES_XT_QTAGUID_SHA256" \
            "${patch_dir}/01-xt_qtaguid-panic.patch"
    else
        echo "xt_qtaguid is not present in this kernel tree; its panic path is absent, so patch 01 is not applicable."
    fi

    apply_droidspaces_patch \
        "restore cgroup file prefixes for Droidspaces/LXC" \
        "${DROIDSPACES_PATCH_BASE}/02.fix_restore%20cgroup%20file%20prefix%20handling%20.patch" \
        "$DROIDSPACES_CGROUP_SHA256" \
        "${patch_dir}/02-cgroup-prefix.patch"

    rm -r -- "$patch_dir"
    echo "Droidspaces ${DROIDSPACES_VERSION} non-GKI runtime patches are ready."
}

configure_droidspaces_non_gki() {
    local out_dir="$1"
    local missing=0 symbol
    local critical_configs=(
        SYSCTL SYSVIPC POSIX_MQUEUE
        NAMESPACES PID_NS UTS_NS IPC_NS
        SECCOMP SECCOMP_FILTER
        CGROUPS CGROUP_DEVICE CGROUP_PIDS MEMCG CGROUP_SCHED
        FAIR_GROUP_SCHED CGROUP_FREEZER
        DEVTMPFS OVERLAY_FS
        NET_NS VETH BRIDGE NETFILTER BRIDGE_NETFILTER
        NF_CONNTRACK IP_NF_IPTABLES IP_NF_FILTER NF_NAT NF_TABLES
        IP_NF_TARGET_MASQUERADE
        NETFILTER_XT_TARGET_TCPMSS NETFILTER_XT_MATCH_ADDRTYPE
        NF_CT_NETLINK NF_NAT_REDIRECT
        IP_ADVANCED_ROUTER IP_MULTIPLE_TABLES
    )

    echo "Enable official Droidspaces non-GKI kernel configuration..."
    scripts/config --file "${out_dir}/.config" \
        -e SYSCTL \
        -e SYSVIPC \
        -e POSIX_MQUEUE \
        -e NAMESPACES \
        -e PID_NS \
        -e UTS_NS \
        -e IPC_NS \
        -e SECCOMP \
        -e SECCOMP_FILTER \
        -e CGROUPS \
        -e CGROUP_DEVICE \
        -e CGROUP_PIDS \
        -e MEMCG \
        -e CGROUP_SCHED \
        -e FAIR_GROUP_SCHED \
        -e CGROUP_FREEZER \
        -e CGROUP_NET_PRIO \
        -e DEVTMPFS \
        -e OVERLAY_FS \
        -e TMPFS_POSIX_ACL \
        -e TMPFS_XATTR \
        -e FW_LOADER \
        -e FW_LOADER_USER_HELPER \
        -e FW_LOADER_COMPRESS \
        -e NET_NS \
        -e VETH \
        -e BRIDGE \
        -e NETFILTER \
        -e BRIDGE_NETFILTER \
        -e NETFILTER_ADVANCED \
        -e NF_CONNTRACK \
        -e IP_NF_IPTABLES \
        -e IP_NF_FILTER \
        -e NF_NAT \
        -e NF_TABLES \
        -e IP_NF_TARGET_MASQUERADE \
        -e NETFILTER_XT_TARGET_MASQUERADE \
        -e NETFILTER_XT_TARGET_TCPMSS \
        -e NETFILTER_XT_MATCH_ADDRTYPE \
        -e NF_CT_NETLINK \
        -e NF_CONNTRACK_NETLINK \
        -e NF_NAT_REDIRECT \
        -e IP_ADVANCED_ROUTER \
        -e IP_MULTIPLE_TABLES \
        -e NF_CONNTRACK_IPV4 \
        -e NF_NAT_IPV4 \
        -e IP_NF_NAT \
        -d USER_NS \
        -d ANDROID_PARANOID_NETWORK

    # Resolve dependencies now
    make "${MAKE_OPTS[@]}" olddefconfig 2>/dev/null || true

    if grep -Eq '^CONFIG_PERF_HUMANTASK=(y|m)$' "${out_dir}/.config"; then
        echo "ERROR: CONFIG_PERF_HUMANTASK was re-enabled by Kconfig."
        echo "Droidspaces container startup is unsafe; aborting before compilation."
        exit 1
    fi
    echo "CONFIG_PERF_HUMANTASK is disabled for Droidspaces compatibility."

    for symbol in "${critical_configs[@]}"; do
        if ! grep -qx "CONFIG_${symbol}=y" "${out_dir}/.config"; then
            echo "ERROR: CONFIG_${symbol}=y did not survive olddefconfig."
            missing=1
        fi
    done

    if [ "$missing" -ne 0 ]; then
        echo "ERROR: Required Droidspaces configuration is incomplete; aborting before compilation."
        exit 1
    fi

    echo "Droidspaces critical configuration verified after olddefconfig."
}

find_ksu_src() {
    local f
    if [ -f KernelSU/kernel/feature/selinux_hide.c ]; then
        printf '%s\n' "KernelSU/kernel"
        return 0
    fi
    if [ -f drivers/kernelsu/feature/selinux_hide.c ]; then
        printf '%s\n' "drivers/kernelsu"
        return 0
    fi
    if [ -f KernelSU/kernel/Kbuild ]; then
        printf '%s\n' "KernelSU/kernel"
        return 0
    fi
    if [ -L drivers/kernelsu ]; then
        printf '%s\n' "drivers/kernelsu"
        return 0
    fi
    while IFS= read -r f; do
        printf '%s\n' "${f%/selinux/rules.c}"
        return 0
    done < <(find . -maxdepth 5 -type f -path '*/selinux/rules.c' -print 2>/dev/null)
    return 1
}

ungate_selinux_hide_feature_id() {
    local ksu_src="$1"
    local f
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        if grep -q 'KSU_FEATURE_SELINUX_HIDE' "$f"; then
            # Drop any leftover 5.10 gate around the feature id.
            python3 - "$f" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text()
orig = text
text = re.sub(
    r"#if\s+LINUX_VERSION_CODE\s*>=\s*KERNEL_VERSION\s*\(\s*5\s*,\s*10\s*,\s*0\s*\)\s*\n\s*(KSU_FEATURE_SELINUX_HIDE\s*=\s*4,?\s*)\n#endif",
    r"\1",
    text,
)
if "KSU_FEATURE_SELINUX_HIDE" not in text:
    text = text.replace(
        "KSU_FEATURE_ADB_ROOT = 3,",
        "KSU_FEATURE_ADB_ROOT = 3,\n    KSU_FEATURE_SELINUX_HIDE = 4,",
    )
if text != orig:
    p.write_text(text)
    print(f"[+] ungated/inserted KSU_FEATURE_SELINUX_HIDE in {p}")
else:
    print(f"[+] feature id already present in {p}")
PY
        fi
    done < <(find "$ksu_src" "$KERNEL_DIR/KernelSU" -name 'feature.h' 2>/dev/null | head -20)
}

ensure_kbuild_obj() {
    local kbuild="$1"
    local obj="$2"
    [ -f "$kbuild" ] || return 0
    if grep -qF "$obj" "$kbuild"; then
        return 0
    fi
    # Insert next to the other feature objects when possible.
    if grep -q 'feature/selinux_hide.o' "$kbuild"; then
        return 0
    fi
    if grep -q 'feature/sucompat.o' "$kbuild"; then
        sed -i "/feature\/sucompat.o/a kernelsu-objs += ${obj}" "$kbuild"
    else
        printf '\nkernelsu-objs += %s\n' "$obj" >> "$kbuild"
    fi
    echo "[+] Kbuild += $obj"
}

patch_ksu_h_backup_externs() {
    local ksu_h="$1"
    [ -f "$ksu_h" ] || return 0
    python3 - "$ksu_h" <<'PY'
from pathlib import Path
import re
import sys
p = Path(sys.argv[1])
text = p.read_text()
if "backup_policydb" in text:
    print("[+] ksu.h already exports backup_policydb")
    raise SystemExit(0)
if "#include <linux/version.h>" not in text:
    text = text.replace("#include <linux/types.h>", "#include <linux/types.h>\n#include <linux/version.h>")
block = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
extern struct selinux_policy *backup_sepolicy;
#else
extern struct policydb *backup_policydb;
extern struct sidtab *backup_sidtab;
#endif
"""
# Current builtin already wraps backup_sepolicy in a 5.10-only #if.
# Replacing only the extern line nests the 4.19 symbols inside that gate.
text2, n = re.subn(
    r"#if\s+LINUX_VERSION_CODE\s*>=\s*KERNEL_VERSION\s*\(\s*5\s*,\s*10\s*,\s*0\s*\)\s*\n"
    r"extern struct selinux_policy \*backup_sepolicy;\s*\n#endif\s*\n",
    block,
    text,
    count=1,
)
if n == 0:
    if "extern struct selinux_policy *backup_sepolicy;" in text:
        text2 = text.replace("extern struct selinux_policy *backup_sepolicy;", block.strip(), 1)
    else:
        text2 = text.replace("#endif", block + "#endif", 1)
p.write_text(text2)
print(f"[+] patched backup externs in {p}")
PY
}

find_ksu_repo() {
    if [ -f KernelSU/kernel/policy/allowlist.c ]; then
        printf '%s\n' "KernelSU"
        return 0
    fi
    if [ -f drivers/kernelsu/policy/allowlist.c ]; then
        printf '%s\n' "drivers/kernelsu"
        return 0
    fi
    return 1
}

# Port of sukisu-manager-compat-v3-v4.patch onto current SukiSU-Ultra builtin.
# The stored patch context is stale (allowlist/ksud/rules/dispatch all moved).
apply_sukisu_manager_compat_logic() {
    local repo="$1"
    local allowlist="$repo/kernel/policy/allowlist.c"
    local ksud="$repo/kernel/runtime/ksud.c"
    local rules="$repo/kernel/selinux/rules.c"
    local dispatch="$repo/kernel/supercall/dispatch.c"

    echo "==========================================="
    echo " [*] Applying SukiSU manager v3/v4 compat"
    echo "==========================================="

    if [ ! -f "$allowlist" ] || [ ! -f "$dispatch" ] || [ ! -f "$rules" ]; then
        echo "WARNING: SukiSU source layout unexpected; skip manager compat"
        return 0
    fi

    python3 - "$allowlist" "$ksud" "$rules" "$dispatch" <<'PY'
from pathlib import Path
import re
import sys

allowlist, ksud, rules, dispatch = map(Path, sys.argv[1:])

def patch_allowlist(p: Path):
    t = p.read_text()
    if "migrated incoming app profile" in t:
        print("[+] allowlist: incoming v2/v3 migrate already present")
        return
    if "static void migrate_profile(" not in t:
        print("WARNING: allowlist has no migrate_profile(); skip incoming migrate")
        return
    if "static void migrate_profile(u32 version, struct app_profile *profile);" not in t:
        t = t.replace(
            "static void release_perm_data(struct kref *ref)",
            "static void migrate_profile(u32 version, struct app_profile *profile);\n\nstatic void release_perm_data(struct kref *ref)",
            1,
        )
    needle = """int ksu_set_app_profile(struct app_profile *profile)
{
    struct perm_data *p, *np;
    int result = 0;

    if (!profile_valid(profile)) {"""
    insert = """int ksu_set_app_profile(struct app_profile *profile)
{
    struct perm_data *p, *np;
    int result = 0;

#if KSU_APP_PROFILE_VER == 4
    if (profile && (profile->version == 2 || profile->version == 3)) {
        u32 old_version = profile->version;
        migrate_profile(old_version, profile);
        pr_info("migrated incoming app profile v%d to v%d: key=%s uid=%d\\n",
                old_version, KSU_APP_PROFILE_VER, profile->key, profile->curr_uid);
    }
#endif

    if (!profile_valid(profile)) {"""
    if needle not in t:
        print("WARNING: allowlist ksu_set_app_profile shape changed; skip")
        return
    p.write_text(t.replace(needle, insert, 1))
    print("[+] allowlist: migrate incoming manager v2/v3 profiles")

def patch_ksud(p: Path):
    if not p.exists():
        print("WARNING: runtime/ksud.c missing; skip throne fallback")
        return
    t = p.read_text()
    if "packages.list may already exist" in t:
        print("[+] ksud: throne fallback already present")
        return
    old = """    ksu_load_allow_list();
    ksu_observer_init();
"""
    new = """    ksu_load_allow_list();
    ksu_observer_init();
    /* packages.list may already exist before the observer is installed. */
    if (unlikely(!ksu_is_manager_appid_valid()))
        track_throne(false);
"""
    if old not in t:
        print("WARNING: ksud on_post_fs_data shape changed; skip throne fallback")
        return
    p.write_text(t.replace(old, new, 1))
    print("[+] ksud: track_throne(false) when manager appid is not ready")

def patch_rules(p: Path):
    t = p.read_text()
    if "Run for both modern and legacy SELinux policy update paths" in t:
        print("[+] rules: susfs_set_batch_sid already dual-path")
        return
    # Drop the 5.10-only call so the shared one is the single site.
    t2 = t.replace(
        """    reset_avc_cache();
#ifdef CONFIG_KSU_SUSFS
    susfs_set_batch_sid();
#endif
out_unlock:""",
        """    reset_avc_cache();
out_unlock:""",
        1,
    )
    if t2 == t:
        t2 = t
    # apply_kernelsu_rules() currently ends with the 5.10/legacy #endif then }.
    m = re.search(
        r"(void apply_kernelsu_rules\(void\)\s*\{.*?\n#endif\n)\}",
        t2,
        re.S,
    )
    if not m:
        print("WARNING: cannot locate apply_kernelsu_rules closer; skip susfs move")
        if t2 != t:
            p.write_text(t2)
        return
    repl = m.group(1) + """
#ifdef CONFIG_KSU_SUSFS
    /* Run for both modern and legacy SELinux policy update paths. */
    susfs_set_batch_sid();
#endif
}"""
    t2 = t2[: m.start()] + repl + t2[m.end() :]
    p.write_text(t2)
    print("[+] rules: susfs_set_batch_sid runs on both SELinux update paths")

def patch_dispatch(p: Path):
    t = p.read_text()
    if "KSU_APP_PROFILE_SIZE_V2_V3" in t:
        print("[+] dispatch: v2/v3 app-profile size already present")
        return
    old_get = """static int do_get_app_profile(void __user *arg)
{
    uid_t uid;
    struct app_profile *profile;
    int ret = 0;

    if (copy_from_user(&uid, (char __user *)arg + offsetof(struct ksu_get_app_profile_cmd, profile.curr_uid),
                       sizeof(uid_t))) {
        pr_err("get_app_profile: copy_from_user failed\\n");
        return -EFAULT;
    }

    rcu_read_lock();
    profile = ksu_get_app_profile(uid);
    rcu_read_unlock();
    if (!profile) {
        ret = -ENOENT;
    } else {
        if (copy_to_user((char __user *)arg + offsetof(struct ksu_get_app_profile_cmd, profile), profile,
                         sizeof(struct app_profile))) {
            pr_err("get_app_profile: copy_to_user failed\\n");
            ret = -EFAULT;
        }
        ksu_put_app_profile(profile);
    }
    return ret;
}"""
    new_get = """#define KSU_APP_PROFILE_SIZE_V2_V3 776U

static size_t app_profile_userspace_size(u32 version)
{
    if (version == 2 || version == 3)
        return KSU_APP_PROFILE_SIZE_V2_V3;

    if (version == KSU_APP_PROFILE_VER)
        return sizeof(struct app_profile);

    return 0;
}

static int do_get_app_profile(void __user *arg)
{
    uid_t uid;
    u32 requested_version;
    size_t profile_size;
    struct app_profile *profile;
    struct app_profile compat_profile;
    const struct app_profile *out_profile;
    int ret = 0;

    if (copy_from_user(&requested_version,
               (char __user *)arg +
               offsetof(struct ksu_get_app_profile_cmd,
                    profile.version),
               sizeof(requested_version))) {
        pr_err("get_app_profile: copy profile version from user failed\\n");
        return -EFAULT;
    }

    if (copy_from_user(&uid, (char __user *)arg + offsetof(struct ksu_get_app_profile_cmd, profile.curr_uid),
               sizeof(uid_t))) {
        pr_err("get_app_profile: copy_from_user failed\\n");
        return -EFAULT;
    }

    profile_size = app_profile_userspace_size(requested_version);
    if (!profile_size) {
        pr_err("get_app_profile: unsupported profile version: %u\\n",
            requested_version);
        return -EINVAL;
    }

    rcu_read_lock();
    profile = ksu_get_app_profile(uid);
    rcu_read_unlock();
    if (!profile) {
        ret = -ENOENT;
    } else {
        out_profile = profile;
        if (profile_size < sizeof(struct app_profile)) {
            memcpy(&compat_profile, profile, sizeof(compat_profile));
            compat_profile.version = requested_version;
            out_profile = &compat_profile;
        }

        if (copy_to_user((char __user *)arg +
                 offsetof(struct ksu_get_app_profile_cmd, profile),
                 out_profile, profile_size)) {
            pr_err("get_app_profile: copy_to_user failed\\n");
            ret = -EFAULT;
        }
        ksu_put_app_profile(profile);
    }
    return ret;
}"""
    old_set = """static int do_set_app_profile(void __user *arg)
{
    struct ksu_set_app_profile_cmd cmd;
    int ret;

    if (copy_from_user(&cmd, arg, sizeof(cmd))) {
        pr_err("set_app_profile: copy_from_user failed\\n");
        return -EFAULT;
    }

    ret = ksu_set_app_profile(&cmd.profile);
    if (!ret)
        ksu_persistent_allow_list();
    return ret;
}"""
    new_set = """static int do_set_app_profile(void __user *arg)
{
    struct ksu_set_app_profile_cmd cmd = { 0 };
    u32 version;
    size_t profile_size;
    int ret;

    if (copy_from_user(&version,
               (char __user *)arg +
               offsetof(struct ksu_set_app_profile_cmd,
                    profile.version),
               sizeof(version))) {
        pr_err("set_app_profile: copy profile version from user failed\\n");
        return -EFAULT;
    }

    profile_size = app_profile_userspace_size(version);
    if (!profile_size) {
        pr_err("set_app_profile: unsupported profile version: %u\\n",
            version);
        return -EINVAL;
    }

    if (copy_from_user(&cmd.profile,
               (char __user *)arg +
               offsetof(struct ksu_set_app_profile_cmd, profile),
               profile_size)) {
        pr_err("set_app_profile: copy_from_user failed\\n");
        return -EFAULT;
    }

    ret = ksu_set_app_profile(&cmd.profile);
    if (!ret)
        ksu_persistent_allow_list();
    return ret;
}"""
    if old_get not in t or old_set not in t:
        print("WARNING: dispatch get/set_app_profile shape changed; skip ABI compat")
        return
    t = t.replace(old_get, new_get, 1).replace(old_set, new_set, 1)
    p.write_text(t)
    print("[+] dispatch: accept manager app-profile ABI v2/v3 (776 bytes)")

patch_allowlist(allowlist)
patch_ksud(ksud)
# Do NOT rewrite apply_kernelsu_rules(). Moving susfs_set_batch_sid onto the
# 4.19 path was enough to panic some devices at first logo.
print("[*] rules.c left unchanged (boot-critical SELinux update path)")
patch_dispatch(dispatch)
PY
    echo "[+] SukiSU manager v3/v4 compat logic applied"
    echo "==========================================="
}

append_dup_policydb_if_missing() {
    local ksu_src="$1"
    local donor="$2"
    local sepolicy="$ksu_src/selinux/sepolicy.c"
    local sepolicy_h="$ksu_src/selinux/sepolicy.h"

    if grep -q 'ksu_dup_policydb' "$sepolicy" 2>/dev/null; then
        echo "[+] ksu_dup_policydb already in sepolicy.c"
        return 0
    fi

    echo "[*] appending self-contained ksu_dup_policydb helpers"
    cat >> "$sepolicy" <<'EOF'

/* hide adapter: 4.19 policydb backup helpers (do not extract from 5.10 #if). */
void ksu_destroy_policydb(struct policydb *db)
{
    if (!db)
        return;
    policydb_destroy(db);
}

int ksu_dup_policydb(struct policydb *old_db, struct policydb *new_db)
{
    void *data;
    size_t len;
    struct policy_file fp;
    int ret;

    if (!old_db || !new_db)
        return -EINVAL;

    len = 2u * 1024u * 1024u;
    data = vmalloc(len);
    if (!data)
        return -ENOMEM;

    fp.data = data;
    fp.len = len;
    ret = policydb_write(old_db, &fp);
    if (ret) {
        vfree(data);
        pr_err("ksu_dup_policydb: policydb_write %d\n", ret);
        return ret;
    }

    memset(new_db, 0, sizeof(*new_db));
    fp.data = data;
    fp.len = len;
    ret = policydb_read(new_db, &fp);
    vfree(data);
    if (ret)
        pr_err("ksu_dup_policydb: policydb_read %d\n", ret);
    return ret;
}
EOF
    echo "[+] appended ksu_dup_policydb/ksu_destroy_policydb"

    if [ -f "$sepolicy_h" ] && ! grep -q 'ksu_dup_policydb' "$sepolicy_h"; then
        python3 - "$sepolicy_h" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
decl = """
int ksu_dup_policydb(struct policydb *old_db, struct policydb *new_db);
void ksu_destroy_policydb(struct policydb *db);
"""
if "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)" in text:
    text = text.replace(
        "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)",
        decl + "\n#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)",
        1,
    )
elif "ksu_dup_sepolicy" in text:
    text = text.replace("struct selinux_policy *ksu_dup_sepolicy", decl + "struct selinux_policy *ksu_dup_sepolicy", 1)
else:
    text = text.rstrip() + decl + "\n"
p.write_text(text)
print("[+] declared ksu_dup_policydb in sepolicy.h")
PY
    fi
}

inject_backup_policydb_into_rules() {
    local rules="$1"
    [ -f "$rules" ] || return 1
    if grep -q 'backup_policydb' "$rules"; then
        echo "[+] rules.c already has backup_policydb"
        return 0
    fi

    python3 - "$rules" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
if "backup_policydb" in text:
    print("[+] rules.c already has backup_policydb")
    raise SystemExit(0)

globals_block = """
struct policydb *backup_policydb;
struct sidtab *backup_sidtab;

static void ksu_backup_policydb_for_hide(void)
{
    struct policydb *src = NULL;
    int ret;

    if (backup_policydb)
        return;

#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0) || defined(KSU_COMPAT_HAS_SELINUX_POLICY_STRUCT)
    if (backup_sepolicy)
        src = &backup_sepolicy->policydb;
#endif
    if (!src && selinux_state.ss)
        src = &selinux_state.ss->policydb;
    if (!src)
        return;

    backup_policydb = kzalloc(sizeof(*backup_policydb), GFP_KERNEL);
    if (!backup_policydb)
        return;
    if (ksu_dup_policydb(src, backup_policydb)) {
        pr_err("failed to dup policydb for hide backup\\n");
        kfree(backup_policydb);
        backup_policydb = NULL;
        return;
    }
    backup_sidtab = kzalloc(sizeof(*backup_sidtab), GFP_KERNEL);
    if (!backup_sidtab) {
        ksu_destroy_policydb(backup_policydb);
        kfree(backup_policydb);
        backup_policydb = NULL;
        return;
    }
    ret = policydb_load_isids(backup_policydb, backup_sidtab);
    if (ret) {
        pr_err("failed to load isids for hide backup: %d\\n", ret);
        kfree(backup_sidtab);
        ksu_destroy_policydb(backup_policydb);
        kfree(backup_policydb);
        backup_policydb = NULL;
        backup_sidtab = NULL;
        return;
    }
    pr_info("backup_policydb success\\n");
}

"""
    # Keep backup_policydb out of the 5.10-only backup_sepolicy #if.
    if "#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)" in text:
        text = text.replace(
            "#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)",
            "#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)\n" + globals_block,
            1,
        )
    elif "struct selinux_policy *backup_sepolicy;" in text:
        text = text.replace(
            "struct selinux_policy *backup_sepolicy;",
            "struct selinux_policy *backup_sepolicy;\n#else\n" + globals_block,
            1,
        )
    else:
        text = text.replace(
            "void apply_kernelsu_rules()",
            globals_block + "void apply_kernelsu_rules()",
            1,
        )

    if "db = get_policydb();" in text and "ksu_backup_policydb_for_hide();" not in text:
        text = text.replace(
            "db = get_policydb();",
            "db = get_policydb();\n    ksu_backup_policydb_for_hide();",
            1,
        )
    else:
        needle = "void apply_kernelsu_rules()\n{"
        insert = "void apply_kernelsu_rules()\n{\n    ksu_backup_policydb_for_hide();"
        if needle in text:
            text = text.replace(needle, insert, 1)
        else:
            text = text.replace(
                "void apply_kernelsu_rules() {",
                "void apply_kernelsu_rules() {\n    ksu_backup_policydb_for_hide();",
                1,
            )
    p.write_text(text)
    print("[+] injected backup_policydb into SukiSU rules.c")
PY
}

write_setprocattr_legacy_stub() {
    local ksu_src="$1"
    local stub="$ksu_src/hook/selinux_hide_lsm_legacy.c"

    # ReSukiSU hide.c on <5.10 references these two helpers. Do not vendor the
    # whole ReSukiSU hook/lsm_hooks.c into SukiSU — it pulls manual-hook deps.
    if grep -q 'ksu_register_setprocattr_lsm_hook' "$ksu_src/feature/selinux_hide.c" 2>/dev/null \
        && ! grep -Rql 'void ksu_register_setprocattr_lsm_hook' "$ksu_src/hook" 2>/dev/null; then
        cat > "$stub" <<'EOF'
#include <linux/version.h>
#include <linux/security.h>

void ksu_register_setprocattr_lsm_hook(void)
{
}

void ksu_unregister_setprocattr_lsm_hook(void)
{
}
EOF
        ensure_kbuild_obj "$ksu_src/Kbuild" "hook/selinux_hide_lsm_legacy.o"
        echo "[+] added weak setprocattr LSM helpers for 4.19 hide"
    fi
}

vendor_hide_from_donor() {
    local ksu_src="$1"
    local donor="$2"

    echo "[*] Vendoring hide sources onto SukiSU from ReSukiSU donor..."

    mkdir -p "$ksu_src/feature" "$ksu_src/compat" "$ksu_src/hook" "$ksu_src/selinux" "$ksu_src/include"

    cp -a "$donor/kernel/feature/selinux_hide.c" "$ksu_src/feature/selinux_hide.c"
    cp -a "$donor/kernel/feature/selinux_hide.h" "$ksu_src/feature/selinux_hide.h"

    if [ ! -f "$ksu_src/compat/kernel_compat.h" ]; then
        cp -a "$donor/kernel/compat/kernel_compat.h" "$ksu_src/compat/kernel_compat.h"
        # Header-only is enough for hide compile flags. Do not add
        # -DKSU_COMPAT_USE_STATIC_KEY; the donor header already defines it.
    fi

    if [ -f "$donor/kernel/hook/patch_memory.h" ] && [ ! -f "$ksu_src/hook/patch_memory.h" ]; then
        cp -a "$donor/kernel/hook/patch_memory.h" "$ksu_src/hook/patch_memory.h"
    fi

    if [ -f "$ksu_src/include/ksu.h" ]; then
        patch_ksu_h_backup_externs "$ksu_src/include/ksu.h"
    elif [ -f "$KERNEL_DIR/KernelSU/kernel/include/ksu.h" ]; then
        patch_ksu_h_backup_externs "$KERNEL_DIR/KernelSU/kernel/include/ksu.h"
    fi

    append_dup_policydb_if_missing "$ksu_src" "$donor"
    inject_backup_policydb_into_rules "$ksu_src/selinux/rules.c"
    write_setprocattr_legacy_stub "$ksu_src"
    ensure_kbuild_obj "$ksu_src/Kbuild" "feature/selinux_hide.o"

    # Do not add -DKSU_COMPAT_USE_STATIC_KEY (Run24 lesson: redefinition).
    # 4.19 Xiaomi uses selinux_state.ss; define the compat flag in Kbuild once.
    if [ -f "$ksu_src/Kbuild" ] && ! grep -q 'KSU_COMPAT_USE_SELINUX_STATE' "$ksu_src/Kbuild"; then
        printf '\nccflags-y += -DKSU_COMPAT_USE_SELINUX_STATE\n' >> "$ksu_src/Kbuild"
        echo "[+] Kbuild += -DKSU_COMPAT_USE_SELINUX_STATE"
    fi

    if ! grep -q 'KSU_FEATURE_SELINUX_HIDE_FALLBACK' "$ksu_src/feature/selinux_hide.c"; then
        python3 - "$ksu_src/feature/selinux_hide.c" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
needle = '#include "policy/feature.h"'
inject = '''#include "policy/feature.h"
#ifndef KSU_FEATURE_SELINUX_HIDE
#define KSU_FEATURE_SELINUX_HIDE 4
#define KSU_FEATURE_SELINUX_HIDE_FALLBACK 1
#endif
'''
if needle in text and "KSU_FEATURE_SELINUX_HIDE_FALLBACK" not in text:
    p.write_text(text.replace(needle, inject, 1))
    print("[+] inserted feature-id fallback in selinux_hide.c")
PY
    fi
}

write_selinux_hide_proof() {
    local ksu_src="$1"
    local proof="${KERNEL_DIR}/selinux_hide_proof.txt"
    {
        echo "SM8250 4.19 SELinux hide integration proof"
        echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "ksu_src: ${ksu_src}"
        echo "setup_url: ${KSU_SETUP_URL}"
        echo
        echo "== feature id =="
        grep -n 'KSU_FEATURE_SELINUX_HIDE' "$ksu_src"/../uapi/feature.h \
            "$ksu_src"/include/uapi/feature.h \
            "$KERNEL_DIR"/KernelSU/uapi/feature.h \
            2>/dev/null || true
        echo
        echo "== hide sources =="
        ls -l "$ksu_src/feature/selinux_hide.c" "$ksu_src/feature/selinux_hide.h" 2>/dev/null || true
        echo
        echo "== backup symbols =="
        grep -n 'backup_policydb\|backup_sidtab\|backup_sepolicy' \
            "$ksu_src/selinux/rules.c" "$ksu_src/include/ksu.h" \
            "$ksu_src/feature/selinux_hide.c" 2>/dev/null | head -40 || true
        echo
        echo "== init registration =="
        grep -n 'ksu_selinux_hide_init' "$ksu_src"/core/init.c "$ksu_src"/ksu.c 2>/dev/null || true
        echo
        echo "== Kbuild =="
        grep -n 'selinux_hide' "$ksu_src/Kbuild" 2>/dev/null || true
        echo
        echo "== ksu_dup_policydb =="
        grep -n 'ksu_dup_policydb' "$ksu_src/selinux/sepolicy.c" "$ksu_src/selinux/sepolicy.h" 2>/dev/null | head || true
    } > "$proof" || true
    echo "[+] wrote $proof"
}

ungate_hide_in_unity_build() {
    local ksu_c="$1/ksu.c"
    [ -f "$ksu_c" ] || return 0
    python3 - "$ksu_c" <<'ENDPY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
orig = t
t = t.replace(
    """#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
#include "feature/selinux_hide.h"
#endif""",
    '#include "feature/selinux_hide.h"',
)
t = t.replace(
    """#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
#include "feature/selinux_hide.c"
#endif""",
    '#include "feature/selinux_hide.c"',
)
t = t.replace(
    """#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
    ksu_selinux_hide_init();
#endif""",
    "    ksu_selinux_hide_init();",
)
t = t.replace(
    """#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
    ksu_selinux_hide_exit();
#endif""",
    "    ksu_selinux_hide_exit();",
)
if t != orig:
    p.write_text(t)
    print("[+] ungated selinux_hide include/init in ksu.c for 4.19")
else:
    print("[+] ksu.c hide include already ungated or layout changed")
ENDPY
}

patch_builtin_hide_for_policydb() {
    local hide="$1/feature/selinux_hide.c"
    [ -f "$hide" ] || return 0
    python3 - "$hide" <<'ENDPY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()

if "#include <linux/version.h>" not in t:
    t = '#include <linux/version.h>\n#include <linux/slab.h>\n' + t
if "struct policydb *backup_policydb;" not in t.split("ksu_selinux_hide_enable", 1)[0]:
    t = t.replace(
        "static DEFINE_MUTEX(selinux_hide_mutex);",
        """#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)
struct policydb *backup_policydb;
struct sidtab *backup_sidtab;
static bool backup_is_shallow;
#endif

static DEFINE_MUTEX(selinux_hide_mutex);""",
        1,
    )

# 4.19 selinux_state has no status_lock / status_page.
old_init_status = """void initialize_fake_status()
{
    mutex_lock(&selinux_state.status_lock);"""
new_init_status = """void initialize_fake_status()
{
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)
    return;
#else
    mutex_lock(&selinux_state.status_lock);"""
if old_init_status in t and "LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)" not in t.split("void initialize_fake_status()", 1)[1][:400]:
    t = t.replace(old_init_status, new_init_status, 1)
    t = t.replace(
        """out:
    mutex_unlock(&selinux_state.status_lock);
}""",
        """out:
    mutex_unlock(&selinux_state.status_lock);
#endif
}""",
        1,
    )

old_enable = """    if (!backup_sepolicy) {
        pr_err("no backup sepolicy available, please save feature and reboot to retry!\\n");
        return -EAGAIN;
    }

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 6, 0)
#else
    fake_state.initialized = true;
    fake_state.policy = backup_sepolicy;
#endif"""
new_enable = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
    if (!backup_sepolicy) {
        pr_err("no backup sepolicy available, please save feature and reboot to retry!\\n");
        return -EAGAIN;
    }
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 6, 0)
    fake_state.initialized = true;
    fake_state.policy = backup_sepolicy;
#endif
#else
    if (!backup_policydb) {
        if (!selinux_state.ss)
            return -EAGAIN;
        /* Lazy snapshot at toggle time. Never run this from apply_kernelsu_rules(). */
        backup_policydb = kmemdup(&selinux_state.ss->policydb, sizeof(struct policydb), GFP_KERNEL);
        backup_sidtab = kmemdup(&selinux_state.ss->sidtab, sizeof(struct sidtab), GFP_KERNEL);
        if (!backup_policydb || !backup_sidtab) {
            kfree(backup_policydb);
            kfree(backup_sidtab);
            backup_policydb = NULL;
            backup_sidtab = NULL;
            return -ENOMEM;
        }
        backup_is_shallow = true;
    }
    fake_state.initialized = true;
    if (!fake_state.ss) {
        fake_state.ss = kzalloc(sizeof(*fake_state.ss), GFP_KERNEL);
        if (!fake_state.ss)
            return -ENOMEM;
    }
    memcpy(&fake_state.ss->policydb, backup_policydb, sizeof(struct policydb));
    if (backup_sidtab)
        memcpy(&fake_state.ss->sidtab, backup_sidtab, sizeof(struct sidtab));
#endif"""
if old_enable in t:
    t = t.replace(old_enable, new_enable, 1)
elif "no backup policydb available" not in t:
    print("WARNING: hide.c enable() shape changed; 4.19 path not patched")

old_exit = """    ksu_unregister_feature_handler(KSU_FEATURE_SELINUX_HIDE);
    mutex_lock(&selinux_state.status_lock);
    if (fake_status)
        __free_page(fake_status);
    fake_status = NULL;
    mutex_unlock(&selinux_state.status_lock);
}"""
new_exit = """    ksu_unregister_feature_handler(KSU_FEATURE_SELINUX_HIDE);
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
    mutex_lock(&selinux_state.status_lock);
    if (fake_status)
        __free_page(fake_status);
    fake_status = NULL;
    mutex_unlock(&selinux_state.status_lock);
#endif
}"""
if old_exit in t:
    t = t.replace(old_exit, new_exit, 1)

old_drop = """    if (!ksu_selinux_hide_running && backup_sepolicy) {
        pr_info("selinux_hide is not enabled - drop backup_sepolicy\\n");
        sidtab_destroy(backup_sepolicy->sidtab);
        kfree(backup_sepolicy->sidtab);
        ksu_destroy_sepolicy(backup_sepolicy);
        backup_sepolicy = NULL;
    }"""
new_drop = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
    if (!ksu_selinux_hide_running && backup_sepolicy) {
        pr_info("selinux_hide is not enabled - drop backup_sepolicy\\n");
        sidtab_destroy(backup_sepolicy->sidtab);
        kfree(backup_sepolicy->sidtab);
        ksu_destroy_sepolicy(backup_sepolicy);
        backup_sepolicy = NULL;
    }
#else
    if (!ksu_selinux_hide_running && backup_policydb) {
        pr_info("selinux_hide is not enabled - drop backup_policydb\\n");
        /* Shallow snapshot shares live policy tables. Do not destroy them. */
        kfree(backup_sidtab);
        kfree(backup_policydb);
        backup_sidtab = NULL;
        backup_policydb = NULL;
        backup_is_shallow = false;
    }
#endif"""
if old_drop in t:
    t = t.replace(old_drop, new_drop, 1)

old_init = """    if (ksu_register_feature_handler(&selinux_hide_handler)) {
        pr_err("Failed to register selinux_hide feature handler\\n");
    }
    static_key_enable(&fake_status_initialize_key.key);
}"""
new_init = """    if (ksu_register_feature_handler(&selinux_hide_handler)) {
        pr_err("Failed to register selinux_hide feature handler\\n");
    }
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
    static_key_enable(&fake_status_initialize_key.key);
#endif
}"""
if old_init in t:
    t = t.replace(old_init, new_init, 1)

p.write_text(t)
print("[+] hide.c adapted for 4.19 without touching boot SELinux update path")
ENDPY
}

integrate_selinux_hide_nongki() {
    local ksu_src donor

    echo "==========================================="
    echo " [*] Integrating SELinux hide onto SukiSU"
    echo "==========================================="

    ksu_src="$(find_ksu_src || true)"
    if [ -z "$ksu_src" ]; then
        echo "ERROR: cannot locate KernelSU sources after setup"
        exit 1
    fi
    echo "[*] KernelSU source: $ksu_src"

    ungate_selinux_hide_feature_id "$ksu_src"
    if [ -f "$ksu_src/include/ksu.h" ]; then
        patch_ksu_h_backup_externs "$ksu_src/include/ksu.h"
    fi

    # Keep apply_kernelsu_rules() and sepolicy.c exactly as SukiSU builtin
    # shipped them. Backup is created lazily in hide.c when the user toggles.
    ungate_hide_in_unity_build "$ksu_src"
    patch_builtin_hide_for_policydb "$ksu_src"
    write_selinux_hide_proof "$ksu_src"

    if ! grep -q 'selinux_hide' "$ksu_src/ksu.c" 2>/dev/null \
        && ! grep -q 'selinux_hide.o' "$ksu_src/Kbuild" 2>/dev/null \
        && ! grep -q 'selinux_hide.o' "$ksu_src/Makefile" 2>/dev/null; then
        echo "ERROR: selinux_hide is not compiled into SukiSU"
        exit 1
    fi
    echo "[+] SELinux hide integration ready."
    echo "==========================================="
}

if [ "$ENABLE_KSU" -eq 1 ]; then
    echo "==========================================="
    echo " [*] Initializing KernelSU Setup"
    echo "==========================================="
    echo "[*] setup script: ${KSU_SETUP_URL}"
    echo "[*] Downloading and running KSU setup script..."

    curl -LSs "$KSU_SETUP_URL" | bash -s builtin

    echo "[+] KernelSU setup finishe
    
    if [ -f drivers/kernelsu/feature/kernel_umount.c ]; then
        echo "[*] Applying patch for kernel_umount.c compile error..."
        sed -i 's/\.set_handler = kernel_umount_feature_set,/.set_handler = NULL,/g' drivers/kernelsu/feature/kernel_umount.c
        echo "[+] Patch applied successfully."
    fi

    KSU_REPO="$(find_ksu_repo || true)"
    if [ -n "$KSU_REPO" ]; then
        apply_sukisu_manager_compat_logic "$KSU_REPO"
    else
        echo "WARNING: cannot locate KernelSU repo for manager compat"
    fi

    if [ "$ENABLE_SELINUX_HIDE" -eq 1 ]; then
        integrate_selinux_hide_nongki
    else
        echo "[*] SELinux hide adapter skipped (nohide)."
    fi
fi

# ==========================================
# Baseband-guard Setup
# ==========================================
echo "==========================================="
echo " [*] Initializing Baseband-guard Setup"
echo "==========================================="
echo "[*] Downloading and running Baseband-guard remote setup script..."
wget -O- https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh | bash

echo "[*] Patching security/Kconfig for baseband_guard..."
sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' security/Kconfig
echo "[+] Baseband-guard setup finished."
echo "==========================================="

# ==========================================
# Droidspaces Source Patch Integration
# ==========================================
echo "==========================================="
echo " [*] Initializing Droidspaces Non-GKI Patches"
echo "==========================================="
integrate_droidspaces_non_gki
echo "[+] Droidspaces patches integrated successfully."
echo "==========================================="

# ==========================================
# AnyKernel3 Setup
# ==========================================
echo "==========================================="
echo " [*] Initializing AnyKernel3 Workspace"
echo "==========================================="
rm -rf anykernel
echo "[*] Cloning AnyKernel3..."
git clone https://github.com/AstideLabs/AnyKernel3 -b master --single-branch --depth=1 anykernel
echo "[+] AnyKernel3 cloned successfully."
echo "==========================================="

# ==========================================
# Modular Build Function
# ==========================================
build_target() {
    local OS_TYPE=$1
    echo "==========================================="
    echo " Starting Kernel Compilation for ${DEVICE_NAME} (Target: $OS_TYPE)"
    echo "==========================================="

    local OUT_DIR="${KERNEL_DIR}/out_${OS_TYPE}"

    # 集中定义 MAKE_OPTS 方便复用
    MAKE_OPTS=(
        -j"$(nproc)"
        O="${OUT_DIR}"
        ARCH="${ARCH}"
        SUBARCH="${SUBARCH}"
        LLVM=1
        LLVM_IAS=1
        CC="ccache clang"
        HOSTCC="ccache clang"
        CROSS_COMPILE="${CROSS_COMPILE}"
        CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32}"
    )

    echo "[*] Cleaning ${OUT_DIR}..."
    rm -rf "${OUT_DIR}"
    mkdir -p "${OUT_DIR}"

    local DTS_SOURCE="arch/arm64/boot/dts/vendor/qcom"
    local DTS_BACKUP=".dts.bak.${OS_TYPE}"

    if [ "$OS_TYPE" == "miui" ]; then
        echo "[*] Applying MIUI DTS patches..."
        cp -a "${DTS_SOURCE}" "${DTS_BACKUP}"

        # Apply MIUI specific sed patches to dts
        sed -i 's/<154>/<1537>/g' ${DTS_SOURCE}/dsi-panel-j1s* || true
        sed -i 's/<154>/<1537>/g' ${DTS_SOURCE}/dsi-panel-j2* || true
        sed -i 's/<155>/<1544>/g' ${DTS_SOURCE}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi || true
        sed -i 's/<155>/<1545>/g' ${DTS_SOURCE}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi || true
        sed -i 's/<155>/<1546>/g' ${DTS_SOURCE}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi || true
        sed -i 's/<155>/<1546>/g' ${DTS_SOURCE}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi || true
        sed -i 's/<70>/<695>/g' ${DTS_SOURCE}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi || true
        sed -i 's/<70>/<695>/g' ${DTS_SOURCE}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi || true
        sed -i 's/<70>/<695>/g' ${DTS_SOURCE}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi || true
        sed -i 's/<70>/<695>/g' ${DTS_SOURCE}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi || true
        sed -i 's/<71>/<710>/g' ${DTS_SOURCE}/dsi-panel-j1s* || true
        sed -i 's/<71>/<710>/g' ${DTS_SOURCE}/dsi-panel-j2* || true

        sed -i 's/\/\/ mi,mdss-dsi-pan-enable-smart-fps/mi,mdss-dsi-pan-enable-smart-fps/g' ${DTS_SOURCE}/dsi-panel* || true
        sed -i 's/\/\/ mi,mdss-dsi-smart-fps-max_framerate/mi,mdss-dsi-smart-fps-max_framerate/g' ${DTS_SOURCE}/dsi-panel* || true
        sed -i 's/\/\/ qcom,mdss-dsi-pan-enable-smart-fps/qcom,mdss-dsi-pan-enable-smart-fps/g' ${DTS_SOURCE}/dsi-panel* || true
        sed -i 's/qcom,mdss-dsi-qsync-min-refresh-rate/\/\/qcom,mdss-dsi-qsync-min-refresh-rate/g' ${DTS_SOURCE}/dsi-panel* || true

        sed -i 's/120 90 60/120 90 60 50 30/g' ${DTS_SOURCE}/dsi-panel-g7a-36-02-0c-dsc-video.dtsi || true
        sed -i 's/120 90 60/120 90 60 50 30/g' ${DTS_SOURCE}/dsi-panel-g7a-37-02-0a-dsc-video.dtsi || true
        sed -i 's/120 90 60/120 90 60 50 30/g' ${DTS_SOURCE}/dsi-panel-g7a-37-02-0b-dsc-video.dtsi || true
        sed -i 's/144 120 90 60/144 120 90 60 50 48 30/g' ${DTS_SOURCE}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi || true

        sed -i 's/\/\/39 00 00 00 00 00 03 51 03 FF/39 00 00 00 00 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 03 51 0D FF/39 00 00 00 00 00 03 51 0D FF/g' ${DTS_SOURCE}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${DTS_SOURCE}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 00 00/39 01 00 00 00 00 03 51 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-38-0c-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${DTS_SOURCE}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${DTS_SOURCE}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${DTS_SOURCE}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${DTS_SOURCE}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${DTS_SOURCE}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${DTS_SOURCE}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${DTS_SOURCE}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 01 00 03 51 03 FF/39 01 00 00 01 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi || true
        sed -i 's/\/\/39 01 00 00 11 00 03 51 03 FF/39 01 00 00 11 00 03 51 03 FF/g' ${DTS_SOURCE}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi || true
    fi

    echo "[*] Making defconfig: ${DEFCONFIG}..."
    make "${MAKE_OPTS[@]}" "${DEFCONFIG}"

    # ----------------------------------------------------
    # Configuration tweaks
    # ----------------------------------------------------

    # 1. Baseband-guard configuration (Always applied)
    echo "[*] Injecting Baseband-guard configuration..."
    scripts/config --file "${OUT_DIR}/.config" -e BBG

    # 2. KernelSU configurations
    if [ "$ENABLE_KSU" -eq 1 ]; then
        echo "[*] Injecting KernelSU & SUSFS configurations..."
        scripts/config --file "${OUT_DIR}/.config" \
           -e KSU \
           -e THREAD_INFO_IN_TASK \
           -e KSU_SUSFS \
           -e KSU_SUSFS_SUS_PATH \
           -e KSU_SUSFS_SUS_MOUNT \
           -e KSU_SUSFS_SUS_KSTAT \
           -e KSU_SUSFS_SPOOF_UNAME \
           -e KSU_SUSFS_ENABLE_LOG \
           -e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
           -e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
           -e KSU_SUSFS_OPEN_REDIRECT \
           -e KSU_SUSFS_SUS_MAP
        # Hide is a runtime feature (id=4), not a Kconfig. KALLSYMS helps
        # write_op / setprocattr resolution on 4.19.
        scripts/config --file "${OUT_DIR}/.config" \
           -e KALLSYMS \
           -e KALLSYMS_ALL || true
    fi


    # 3. Droidspaces Non-GKI configurations
    echo "[*] Injecting Droidspaces Non-GKI configurations..."
    configure_droidspaces_non_gki "${OUT_DIR}"

    # 4. MIUI configurations
    if [ "$OS_TYPE" == "miui" ]; then
        echo "[*] Injecting MIUI specific configurations..."
        scripts/config --file "${OUT_DIR}/.config" \
    --set-str STATIC_USERMODEHELPER_PATH /system/bin/micd \
    -e PERF_CRITICAL_RT_TASK        \
    -e SF_BINDER                \
    -e OVERLAY_FS                \
    -e MIGT \
    -e MIGT_ENERGY_MODEL \
    -e MIHW \
    -e PACKAGE_RUNTIME_INFO \
    -e BINDER_OPT \
    -e KPERFEVENTS \
    -e MILLET \
    -d PERF_HUMANTASK \
    -d LTO_CLANG \
    -e LTO_NONE \
    -e SF_BINDER \
    -e XIAOMI_MIUI \
    -d MI_MEMORY_SYSFS \
    -e TASK_DELAY_ACCT \
    -e MIUI_ZRAM_MEMORY_TRACKING \
    -e MI_FRAGMENTION \
    -e PERF_HELPER \
    -e BOOTUP_RECLAIM \
    -e MI_RECLAIM \
    -e RTMM \
    -d REKERNEL \
    -d REKERNEL_NETWORK
    fi

    # We always need to re-evaluate dependencies because BBG and Droidspaces are injected
    echo "[*] Updating config (make olddefconfig)..."
    make "${MAKE_OPTS[@]}" olddefconfig

    # ----------------------------------------------------
    # Compilation
    # ----------------------------------------------------
    echo "[*] Building kernel..."
    make "${MAKE_OPTS[@]}" 

    # Restore DTS backup for MIUI
    if [ "$OS_TYPE" == "miui" ]; then
        echo "[*] Restoring DTS backups..."
        rm -rf "${DTS_SOURCE}"
        mv "${DTS_BACKUP}" "${DTS_SOURCE}"
    fi

    echo "==========================================="
    if [ -f "${OUT_DIR}/arch/arm64/boot/Image" ]; then
        echo "[+] $OS_TYPE Build Successful!"
        echo "[+] Kernel Image path: ${OUT_DIR}/arch/arm64/boot/Image"

        echo "[*] Generating dtb..."
        find "${OUT_DIR}/arch/arm64/boot/dts" -name '*.dtb' -exec cat {} + > "${OUT_DIR}/arch/arm64/boot/dtb"

        echo "[*] Packaging to AnyKernel3 ($OS_TYPE)..."
        rm -rf anykernel/kernels/*
        mkdir -p "anykernel/kernels/${OS_TYPE}/"

        cp "${OUT_DIR}/arch/arm64/boot/Image" "anykernel/kernels/${OS_TYPE}/"
        cp "${OUT_DIR}/arch/arm64/boot/dtb" "anykernel/kernels/${OS_TYPE}/"

        if [ -f "${OUT_DIR}/arch/arm64/boot/dtbo.img" ]; then
            cp "${OUT_DIR}/arch/arm64/boot/dtbo.img" "anykernel/kernels/${OS_TYPE}/"
        fi

        if [ -f "${KERNEL_DIR}/selinux_hide_proof.txt" ]; then
            cp "${KERNEL_DIR}/selinux_hide_proof.txt" "anykernel/selinux_hide_proof.txt"
        fi

        local KSU_ZIP_STR="NoKernelSU"
        if [ "$ENABLE_KSU" -eq 1 ]; then
            KSU_ZIP_STR="SukiSU-SUSFS"
            if [ "$ENABLE_SELINUX_HIDE" -eq 1 ]; then
                KSU_ZIP_STR="SukiSU-SUSFS-Hide"
            fi
        fi
        local GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD 2>/dev/null || echo "unknown")
        local OS_UPPER=$(echo "$OS_TYPE" | tr '[:lower:]' '[:upper:]')
        local ZIP_FILENAME="APTKernel_${OS_UPPER}_${DEVICE_NAME}_${KSU_ZIP_STR}_$(date +'%Y%m%d_%H%M%S')_anykernel3_${GIT_COMMIT_ID}.zip"

        echo "[*] Zipping $ZIP_FILENAME ..."
        pushd anykernel > /dev/null
        zip -r9 "$ZIP_FILENAME" ./* -x .git .gitignore out/ ./*.zip > /dev/null
        mv "$ZIP_FILENAME" ../
        popd > /dev/null

        echo "[+] $OS_TYPE kernel binaries successfully packed into: $ZIP_FILENAME"
    else
        echo "[-] $OS_TYPE Build Failed. Kernel Image not found."
        exit 1
    fi
}

# ==========================================
# Execute builds based on target OS
# ==========================================
if [ "$TARGET_OS" == "aosp" ] || [ "$TARGET_OS" == "both" ]; then
    build_target "aosp"
fi

if [ "$TARGET_OS" == "miui" ] || [ "$TARGET_OS" == "both" ]; then
    build_target "miui"
fi

echo "==========================================="
echo "[*] ccache stats:"
ccache -s
echo "[+] All requested builds completed!"
