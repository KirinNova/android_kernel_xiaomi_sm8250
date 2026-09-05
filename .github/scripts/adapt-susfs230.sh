#!/usr/bin/env bash
set -Eeuo pipefail

cd "${GITHUB_WORKSPACE:-.}"
exec > >(tee "$GITHUB_WORKSPACE/adapt-susfs230.log") 2>&1

echo '===== Backport official GKI SUSFS v2.3.0 onto Linux 4.19 i_state + fsnotify_add_mark ====='
test -f include/linux/susfs.h
test -f include/linux/susfs_def.h
test -f fs/susfs.c
test -f fs/proc/task_mmu.c

GKI_BASE='https://gitlab.com/simonpunk/susfs4ksu/-/raw/gki-android12-5.10/kernel_patches'
mkdir -p "$GITHUB_WORKSPACE/.susfs23-upstream"
curl -fLSs "$GKI_BASE/fs/susfs.c" -o "$GITHUB_WORKSPACE/.susfs23-upstream/susfs.c"
curl -fLSs "$GKI_BASE/include/linux/susfs.h" -o "$GITHUB_WORKSPACE/.susfs23-upstream/susfs.h"
curl -fLSs "$GKI_BASE/include/linux/susfs_def.h" -o "$GITHUB_WORKSPACE/.susfs23-upstream/susfs_def.h"
grep -Fq '#define SUSFS_VERSION "v2.3.0"' "$GITHUB_WORKSPACE/.susfs23-upstream/susfs.h"
grep -Fq '#define TIF_PROC_NO_SU 34' "$GITHUB_WORKSPACE/.susfs23-upstream/susfs_def.h"
grep -Fq 'i_mapping->flags' "$GITHUB_WORKSPACE/.susfs23-upstream/susfs.c"

python3 -u - <<'PY'
from pathlib import Path
import os

ws = Path(os.environ['GITHUB_WORKSPACE'])
up = ws / '.susfs23-upstream'
gki_c = (up / 'susfs.c').read_text()
gki_h = (up / 'susfs.h').read_text()
gki_d = (up / 'susfs_def.h').read_text()
old_c = Path('fs/susfs.c').read_text()
if '#define SUSFS_VERSION "v2.3.0"' not in gki_h:
    raise SystemExit('upstream susfs.h is not v2.3.0')

old_start = old_c.find('static SUSFS_DECL_FSNOTIFY_OPS(susfs_handle_sdcard_inode_event)')
old_end = old_c.find('static int susfs_sdcard_monitor_fn')
if old_start < 0 or old_end < 0:
    raise SystemExit('cannot extract 4.19 fsnotify compatibility block')

c = gki_c.replace('i_mapping->flags', 'i_state')
d = gki_d.replace('inode->i_mapping->flags', 'inode->i_state')
d = d.replace('i_mapping->flags', 'i_state')
d = d.replace(
    "inode->i_mapping->flags => A 'unsigned long' type storing flag 'AS_FLAGS_",
    "inode->i_state => A 'unsigned long' type storing flag 'AS_FLAGS_",
)

if '#include <linux/version.h>' not in d:
    if '#include <linux/bits.h>' in d:
        d = d.replace(
            '#include <linux/bits.h>',
            '#include <linux/bits.h>\n#include <linux/version.h>\n#include <linux/cred.h>',
            1,
        )
    else:
        d = d.replace(
            '#define KSU_SUSFS_DEF_H',
            '#define KSU_SUSFS_DEF_H\n\n#include <linux/version.h>\n#include <linux/cred.h>',
            1,
        )

if 'SUSFS_DECL_FSNOTIFY_OPS' not in d:
    helper = r'''
/* 4.19 / non-GKI fsnotify compatibility */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 2, 0)
typedef const struct qstr *susfs_fname_t;
#define susfs_fname_len(f) ((f)->len)
#define susfs_fname_arg(f) ((f)->name)
#else
typedef const unsigned char *susfs_fname_t;
#define susfs_fname_len(f) (strlen(f))
#define susfs_fname_arg(f) (f)
#endif

#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)
#define SUSFS_DECL_FSNOTIFY_OPS(name)                                            \
int name(struct fsnotify_mark *mark, u32 mask, struct inode *inode,    \
struct inode *dir, const struct qstr *file_name, u32 cookie)
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(4, 18, 0)
#define SUSFS_DECL_FSNOTIFY_OPS(name)                                            \
int name(struct fsnotify_group *group, struct inode *inode, u32 mask,  \
const void *data, int data_type, susfs_fname_t file_name,       \
u32 cookie, struct fsnotify_iter_info *iter_info)
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(4, 12, 0)
#define SUSFS_DECL_FSNOTIFY_OPS(name)                                            \
int name(struct fsnotify_group *group, struct inode *inode,            \
struct fsnotify_mark *inode_mark,                             \
struct fsnotify_mark *vfsmount_mark, u32 mask,                \
const void *data, int data_type, susfs_fname_t file_name,       \
u32 cookie, struct fsnotify_iter_info *iter_info)
#else
#define SUSFS_DECL_FSNOTIFY_OPS(name)                                            \
int name(struct fsnotify_group *group, struct inode *inode,            \
struct fsnotify_mark *inode_mark,                             \
struct fsnotify_mark *vfsmount_mark, u32 mask, void *data,    \
int data_type, susfs_fname_t file_name, u32 cookie)
#endif
'''
    d = d.replace('#endif // #ifndef KSU_SUSFS_DEF_H', helper + '\n#endif // #ifndef KSU_SUSFS_DEF_H')

d = d.replace(
    '''static inline bool susfs_is_current_proc_umounted_app(void) {
	return (likely(test_thread_flag(TIF_PROC_UMOUNTED)) &&
			current_uid().val >= 10000);
}''',
    '''static inline bool susfs_is_current_proc_umounted_app(void) {
	return (likely(test_thread_flag(TIF_PROC_UMOUNTED)) &&
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 12, 0)
			__kuid_val(current_uid()) >= 10000);
#else
			current_uid().val >= 10000);
#endif
}'''
)

g_start = c.find('static int susfs_handle_sdcard_inode_event')
g_end = c.find('static int susfs_sdcard_monitor_fn')
if g_start < 0 or g_end < 0:
    raise SystemExit('cannot find GKI fsnotify block to replace')
c = c[:g_start] + old_c[old_start:old_end] + c[g_end:]

if 'int susfs_open_redirect_spoof_show_map_vma(' not in c:
    wrap = '''
#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
int susfs_open_redirect_spoof_show_map_vma(struct inode *inode, unsigned long *out_ino, dev_t *out_dev, char *spoofed_name)
{
	char *name = NULL;
	int ret;

	if (!spoofed_name)
		return 0;
	ret = susfs_open_redirect_spoof_show_map_vma_srcu(inode, out_ino, out_dev, &name);
	if (ret && name)
		strscpy(spoofed_name, name, SUSFS_MAX_LEN_PATHNAME);
	return ret;
}
#endif
'''
    needle = 'void susfs_start_sdcard_monitor_fn(void)'
    if needle not in c:
        raise SystemExit('cannot insert 4.19 OPEN_REDIRECT wrapper')
    c = c.replace(needle, wrap + '\n' + needle, 1)

if 'i_mapping->flags' in c or 'i_mapping->flags' in d:
    raise SystemExit('i_mapping->flags still present after rewrite')
if '#include <linux/version.h>' not in d:
    raise SystemExit('susfs_def.h missing linux/version.h')
if 'SUSFS_DECL_FSNOTIFY_OPS' not in d or 'SUSFS_DECL_FSNOTIFY_OPS' not in c:
    raise SystemExit('4.19 fsnotify decl missing')
if 'fsnotify_add_mark' not in c and 'fsnotify_add_inode_mark' not in c:
    raise SystemExit('fsnotify mark API missing')
if 'TIF_PROC_NO_SU' not in d or 'TIF_PROC_UMOUNTED_FOR_ZYGOTE_NEXT' not in d:
    raise SystemExit('2.3 TIF helpers missing')
if 'susfs_open_redirect_spoof_show_map_vma_srcu' not in c:
    raise SystemExit('2.3 OPEN_REDIRECT srcu helper missing')

Path('include/linux/susfs.h').write_text(gki_h)
Path('include/linux/susfs_def.h').write_text(d)
Path('fs/susfs.c').write_text(c)
print('overlaid GKI v2.3.0 susfs.c/h/def.h with 4.19 i_state + fsnotify_add_mark', flush=True)
PY

grep -Fq '#define SUSFS_VERSION "v2.3.0"' include/linux/susfs.h
grep -Fq '#include <linux/version.h>' include/linux/susfs_def.h
grep -Fq '#define TIF_PROC_NO_SU 34' include/linux/susfs_def.h
grep -Fq 'susfs_is_current_proc_no_su' include/linux/susfs_def.h

echo '===== Rewrite 4.19 2.2 hook sites to official SUSFS 2.3 ====='
python3 -u .github/scripts/rewrite-susfs230-hooks.py

grep -Fq 'susfs_is_current_proc_no_su()' fs/exec.c
grep -Fq 'filename_lookup(dfd, fname, lookup_flags, &path, NULL)' fs/open.c
grep -Fq 'filename_lookup(dfd, fname, lookup_flags, &path, NULL)' fs/stat.c
! grep -F 'susfs_is_current_proc_umounted()' fs/exec.c
! grep -F 'susfs_is_current_proc_umounted()' fs/open.c
! grep -F 'susfs_is_current_proc_umounted()' fs/stat.c

python3 -u - <<'PY'
from pathlib import Path
for p in (Path('fs/susfs.c'), Path('include/linux/susfs.h'), Path('include/linux/susfs_def.h'), Path('fs/open.c'), Path('fs/exec.c'), Path('fs/stat.c')):
    text = p.read_text()
    lines = [ln.rstrip(' \t') for ln in text.splitlines()]
    while lines and lines[-1] == '':
        lines.pop()
    p.write_text('\n'.join(lines) + '\n')
    print('stripped trailing whitespace:', p, flush=True)
PY

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git add fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h fs/open.c fs/exec.c fs/stat.c
  git diff --cached --check
fi

{
  echo "base=$GITHUB_SHA"
  echo 'baseline_branch=sync/android16-upstream-20260830'
  echo 'resukisu=v4.2.0-rc1'
  echo 'susfs_upstream=gki-android12-5.10 v2.3.0'
  echo 'susfs_to=v2.3.0'
  echo 'flag_storage=inode_i_state'
  echo 'hooks=exec.c no_su; open.c/stat.c getname_flags+filename_lookup+filename**'
  echo 'refs=simonpunk da34bba1 f3087ec1 + JackA1ltman susfs_inline_hook_patches.sh'
} | tee "$GITHUB_WORKSPACE/adapt-susfs230-proof.txt"

echo '[PASS] official GKI SUSFS 2.3.0 core + 4.19 hook rewrite'
