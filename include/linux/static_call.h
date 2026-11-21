/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _LINUX_STATIC_CALL_H
#define _LINUX_STATIC_CALL_H

/*
 * Compatibility shim for Linux 4.19.
 *
 * static_call() and its DEFINE_STATIC_CALL()/static_call_update() family were
 * introduced in 5.10.  This tree predates them and has no equivalent, so the
 * header is intentionally empty.
 *
 * It exists because some external modules (KernelSU forks among them) include
 * <linux/static_call.h> unconditionally while only using the API on kernels
 * that actually provide it.  If code compiled against this tree ever starts
 * calling static_call(), this stub has to be replaced by a real implementation
 * rather than extended.
 */

#endif /* _LINUX_STATIC_CALL_H */
