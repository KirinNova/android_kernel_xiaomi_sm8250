/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _LINUX_HEX_H
#define _LINUX_HEX_H

/*
 * Compatibility shim for Linux 4.19.
 *
 * linux/hex.h was split out of linux/kernel.h much later, so this tree has
 * no such header even though the helpers themselves exist.  On 4.19 they are
 * declared in linux/kernel.h:
 *
 *	hex_to_bin(), hex2bin(), bin2hex()
 *
 * Some external modules (KernelSU forks among them) include <linux/hex.h>
 * unconditionally, so provide the header and forward to the real one.
 */

#include <linux/kernel.h>

#endif /* _LINUX_HEX_H */
