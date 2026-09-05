#!/usr/bin/env python3
"""Rewrite 4.19 2.2 inline hooks to official SUSFS 2.3 logic.

Mirrors:
  gitlab.com/simonpunk/susfs4ksu
    da34bba1 (getname_flags + filename_lookup + filename** handlers)
    f3087ec1 (sucompat early-out uses TIF_PROC_NO_SU, not TIF_PROC_UMOUNTED)
  and JackA1ltman/NonGKI_Kernel_Build_2nd Patches/susfs_inline_hook_patches.sh
"""
from pathlib import Path

def must_replace(text, old, new, label):
    if old not in text:
        raise SystemExit(f'{label}: expected block not found')
    return text.replace(old, new, 1)


# ---- fs/exec.c : TIF_PROC_UMOUNTED -> TIF_PROC_NO_SU ----
p = Path('fs/exec.c')
t = p.read_text()
old = """#ifdef CONFIG_KSU_SUSFS
	if (likely(susfs_is_current_proc_umounted()))
		goto orig_flow;
"""
new = """#ifdef CONFIG_KSU_SUSFS
	if (likely(susfs_is_current_proc_no_su()))
		goto orig_flow;
"""
t = must_replace(t, old, new, 'fs/exec.c early-out')
p.write_text(t)
print('rewrote fs/exec.c sucompat early-out to susfs_is_current_proc_no_su', flush=True)


# ---- fs/open.c : getname_flags + filename_lookup + filename** ----
p = Path('fs/open.c')
t = p.read_text()
old = """extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,
			int *flags);
#endif
long do_faccessat(int dfd, const char __user *filename, int mode)
{
	const struct cred *old_cred;
	struct cred *override_cred;
	struct path path;
	struct inode *inode;
	struct vfsmount *mnt;
	int res;
	unsigned int lookup_flags = LOOKUP_FOLLOW;

#ifdef CONFIG_KSU_SUSFS
	if (likely(susfs_is_current_proc_umounted()))
		goto orig_flow;
	if (static_branch_likely(&ksu_su_compat_enabled))
		if (unlikely(__ksu_is_allow_uid_for_current(current_uid().val))) {
			ksu_handle_faccessat(&dfd, &filename, &mode, NULL);
	}

orig_flow:
#endif
"""
new = """extern int ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode,
			int *flags);
#endif
long do_faccessat(int dfd, const char __user *filename, int mode)
{
	const struct cred *old_cred;
	struct cred *override_cred;
	struct path path;
	struct inode *inode;
	struct vfsmount *mnt;
	int res;
	unsigned int lookup_flags = LOOKUP_FOLLOW;
#ifdef CONFIG_KSU_SUSFS
	struct filename *fname = NULL;
#endif
"""
t = must_replace(t, old, new, 'fs/open.c proto + early-out')

old = """retry:
	res = user_path_at(dfd, filename, lookup_flags, &path);
	if (res)
		goto out;
"""
new = """retry:
#ifdef CONFIG_KSU_SUSFS
	fname = getname_flags(filename, lookup_flags, NULL);
	if (likely(susfs_is_current_proc_no_su()))
		goto orig_faccessat;
	if (static_branch_likely(&ksu_su_compat_enabled)) {
		if (unlikely(__ksu_is_allow_uid_for_current(current_uid().val)))
			ksu_handle_faccessat(&dfd, &fname, &mode, NULL);
	}
orig_faccessat:
	res = filename_lookup(dfd, fname, lookup_flags, &path, NULL);
#else
	res = user_path_at(dfd, filename, lookup_flags, &path);
#endif
	if (res)
		goto out;
"""
t = must_replace(t, old, new, 'fs/open.c user_path_at')
p.write_text(t)
print('rewrote fs/open.c do_faccessat to getname_flags + filename_lookup', flush=True)


# ---- fs/stat.c : same split ----
p = Path('fs/stat.c')
t = p.read_text()
if '#include "internal.h"' not in t:
    if '#include <linux/syscalls.h>' in t:
        t = t.replace('#include <linux/syscalls.h>',
                      '#include <linux/syscalls.h>\n#include "internal.h"', 1)
    else:
        t = '#include "internal.h"\n' + t

old = """extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);
#endif

int vfs_statx(int dfd, const char __user *filename, int flags,
	      struct kstat *stat, u32 request_mask)
{
	struct path path;
	int error = -EINVAL;
	unsigned int lookup_flags = LOOKUP_FOLLOW | LOOKUP_AUTOMOUNT;

#ifdef CONFIG_KSU_SUSFS
	if (likely(susfs_is_current_proc_umounted()))
		goto orig_flow;
	if (static_branch_likely(&ksu_su_compat_enabled)) {
		if (unlikely(__ksu_is_allow_uid_for_current(current_uid().val)))
			ksu_handle_stat(&dfd, &filename, &flags);
	}
orig_flow:
#endif
"""
new = """extern int ksu_handle_stat(int *dfd, struct filename **filename, int *flags);
#endif

int vfs_statx(int dfd, const char __user *filename, int flags,
	      struct kstat *stat, u32 request_mask)
{
	struct path path;
	int error = -EINVAL;
	unsigned int lookup_flags = LOOKUP_FOLLOW | LOOKUP_AUTOMOUNT;
#ifdef CONFIG_KSU_SUSFS
	struct filename *fname = NULL;
#endif
"""
t = must_replace(t, old, new, 'fs/stat.c proto + early-out')

old = """retry:
	error = user_path_at(dfd, filename, lookup_flags, &path);
	if (error)
		goto out;
"""
new = """retry:
#ifdef CONFIG_KSU_SUSFS
	fname = getname_flags(filename, lookup_flags, NULL);
	if (likely(susfs_is_current_proc_no_su()))
		goto orig_statx;
	if (static_branch_likely(&ksu_su_compat_enabled)) {
		if (unlikely(__ksu_is_allow_uid_for_current(current_uid().val)))
			ksu_handle_stat(&dfd, &fname, &flags);
	}
orig_statx:
	error = filename_lookup(dfd, fname, lookup_flags, &path, NULL);
#else
	error = user_path_at(dfd, filename, lookup_flags, &path);
#endif
	if (error)
		goto out;
"""
t = must_replace(t, old, new, 'fs/stat.c user_path_at')
p.write_text(t)
print('rewrote fs/stat.c vfs_statx to getname_flags + filename_lookup', flush=True)

# sanity
for f, needles, forbidden in (
    ('fs/exec.c', ['susfs_is_current_proc_no_su()'], []),
    ('fs/open.c', ['getname_flags(filename, lookup_flags, NULL)',
                   'filename_lookup(dfd, fname, lookup_flags, &path, NULL)',
                   'ksu_handle_faccessat(&dfd, &fname, &mode, NULL)',
                   'susfs_is_current_proc_no_su()'],
     ['ksu_handle_faccessat(&dfd, &filename']),
    ('fs/stat.c', ['getname_flags(filename, lookup_flags, NULL)',
                   'filename_lookup(dfd, fname, lookup_flags, &path, NULL)',
                   'ksu_handle_stat(&dfd, &fname, &flags)',
                   'susfs_is_current_proc_no_su()'],
     ['ksu_handle_stat(&dfd, &filename']),
):
    text = Path(f).read_text()
    for n in needles:
        if n not in text:
            raise SystemExit(f'{f} missing {n!r}')
    for n in forbidden:
        if n in text:
            raise SystemExit(f'{f} still has 2.2 call {n!r}')

print('hook rewrite verified', flush=True)
