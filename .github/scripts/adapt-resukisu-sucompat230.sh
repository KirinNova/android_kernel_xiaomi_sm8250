#!/usr/bin/env bash
set -Eeuo pipefail
echo '===== Align ReSukiSU sucompat handlers with SUSFS 2.3 ====='
CANDIDATES=(KernelSU/kernel/feature/sucompat.c drivers/kernelsu/feature/sucompat.c KernelSU/kernel/sucompat.c)
HDR_CANDIDATES=(KernelSU/kernel/feature/sucompat.h drivers/kernelsu/feature/sucompat.h KernelSU/kernel/sucompat.h)
SUC=
for f in "${CANDIDATES[@]}"; do [[ -f "$f" ]] && SUC="$f" && break; done
if [[ -z "$SUC" ]]; then SUC=$(find . -path './.git' -prune -o -name 'sucompat.c' -print | head -n1 || true); fi
[[ -n "$SUC" && -f "$SUC" ]] || { echo sucompat.c not found; find . -name sucompat.c | head; exit 1; }
HDR=
for f in "${HDR_CANDIDATES[@]}"; do [[ -f "$f" ]] && HDR="$f" && break; done
[[ -n "$HDR" ]] || HDR=$(dirname "$SUC")/sucompat.h
echo using "$SUC" "$HDR"

python3 -u - "$SUC" "$HDR" <<'PY'
from pathlib import Path
import sys
suc, hdr = Path(sys.argv[1]), Path(sys.argv[2])
t = suc.read_text()

old = """#ifdef CONFIG_KSU_SUSFS
            if (!susfs_is_current_proc_umounted())
                susfs_set_current_proc_umounted();
#endif"""
new = """#ifdef CONFIG_KSU_SUSFS
            if (!susfs_is_current_proc_no_su())
                susfs_set_current_proc_no_su();
#endif"""
if old in t:
    t = t.replace(old, new, 1)
    print('exec init: umounted -> no_su', flush=True)
elif 'susfs_set_current_proc_no_su()' in t or 'ksu_set_current_proc_unprivillege()' in t:
    print('exec init already no_su / unprivillege', flush=True)
else:
    print('WARN: no umounted/no_su exec-init mark; continue', flush=True)

gate = '#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0) && defined(CONFIG_KSU_SUSFS)'
if gate in t:
    t = t.replace(gate, '#if defined(CONFIG_KSU_SUSFS)', 1)
    print('stat: drop 6.1 gate so filename** works on 4.19', flush=True)
else:
    print('no 6.1 SUSFS stat gate (likely latest ReSukiSU)', flush=True)

old_fa = 'int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *__unused_flags)'
new_fa = 'int ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode, int *__unused_flags)'
new_st = 'int ksu_handle_stat(int *dfd, struct filename **filename, int *flags)'
if new_fa in t and new_st in t:
    print('faccessat/stat already filename**', flush=True)
elif old_fa not in t:
    raise SystemExit('cannot find ksu_handle_faccessat user-pointer impl and no filename** form')
else:
    st_start = t.find(new_st)
    if st_start < 0:
        raise SystemExit('filename** stat handler not found')
    st_end = t.find('\n}\n', st_start)
    if st_end < 0:
        raise SystemExit('cannot find end of filename** stat handler')
    st_fn = t[st_start:st_end + 3]
    fa_fn = st_fn.replace(new_st, new_fa, 1)
    fa_fn = fa_fn.replace('ksu_handle_stat: su->sh!', 'faccessat su->sh!', 1)
    fa_start = t.find(old_fa)
    fa_end = t.find('\n}\n', fa_start)
    if fa_end < 0:
        raise SystemExit('cannot find end of faccessat')
    t = t[:fa_start] + fa_fn + t[fa_end + 3:]
    print('faccessat: cloned filename** stat handler', flush=True)

# Latest ReSukiSU SUSFS handlers call static_branch_unlikely even when
# ksu_su_compat_enabled is a plain bool on 4.19. Guard that.
unguarded = '''    if (!static_branch_unlikely(&ksu_su_compat_enabled)) {
        return 0;
    }'''
guarded = '''#ifdef KSU_COMPAT_USE_STATIC_KEY
    if (!static_branch_unlikely(&ksu_su_compat_enabled)) {
        return 0;
    }
#else
    if (!ksu_su_compat_enabled) {
        return 0;
    }
#endif'''
if unguarded in t:
    t = t.replace(unguarded, guarded)
    print('wrapped unguarded static_branch_unlikely for 4.19 bool key', flush=True)

if '#include <linux/fs.h>' not in t:
    needle = '#include <linux/susfs_def.h>'
    if needle in t:
        t = t.replace(needle, needle + '\n#include <linux/fs.h>\n#include <linux/err.h>', 1)
        print('added fs.h/err.h', flush=True)

for i, line in enumerate(t.splitlines(), 1):
    if 'pr_info(' in line and line.count('"') % 2 == 1:
        raise SystemExit('unterminated pr_info on line %d: %r' % (i, line))

suc.write_text(t)

if hdr.exists():
    h = hdr.read_text()
    if old_fa + ';' in h:
        h = h.replace(old_fa + ';', new_fa + ';')
    if gate in h:
        h = h.replace(gate, '#if defined(CONFIG_KSU_SUSFS)')
    if new_fa not in h and 'struct filename **filename' not in h:
        raise SystemExit('header faccessat prototype not updated')
    hdr.write_text(h)
    print('updated', hdr, flush=True)

print('[PASS] sucompat text rewritten', flush=True)
PY

grep -Eq 'susfs_set_current_proc_no_su|ksu_set_current_proc_unprivillege|filename \*\*filename' "$SUC"
grep -Fq 'int ksu_handle_faccessat(int *dfd, struct filename **filename' "$SUC"
grep -Fq 'int ksu_handle_stat(int *dfd, struct filename **filename' "$SUC"
echo '[PASS] ReSukiSU sucompat aligned to SUSFS 2.3 filename** handlers'
