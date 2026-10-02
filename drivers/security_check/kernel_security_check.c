/****************************************************************
* File: kernel_security_check.c
* Author: cenjun
* Data: 2025-7-20
* Version 1.5 (Fixed for Linux 4.19 ARM64, K40 alioth)
* Desc: 内核完整性检测，包括系统调用表劫持检测和ko完整性检测
******************************************************************/

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kprobes.h>
#include <linux/elf.h>
#include <linux/init.h>
#include <crypto/hash.h>
#include <linux/seq_file.h>
#include <linux/string.h>
#include <linux/workqueue.h>
#include <linux/jiffies.h>
#include <linux/proc_fs.h>
#include <linux/cred.h>
#include <linux/mutex.h>
#include <linux/hashtable.h>
#include <linux/jhash.h>
#include <linux/rwlock.h>
#include <linux/uidgid.h>
#include <linux/slab.h>
#include <linux/kallsyms.h>
#include <asm/unistd.h>

/***************** config ************************************/
#define SHA256_DIGEST_SIZE 32
#define CHUNK_SIZE 4096
#define MAX_ENTRIES 1000
#define FILENAME_LEN 40
#define INTE_HASH_SIZE 32
#define INTE_HASH_BITS 10
#define MAX_EVENTS_COUNT 10
#define KO_EVENT_FLAG 10000
#define BOOT_COMPLETE 1

/* 强制打开调试触发接口（4.19 上不容易同时开 3 个 DEBUG config） */
#define CHECK_DEBUG 1

struct hash_entry {
    char filename[FILENAME_LEN];
    unsigned char hash[INTE_HASH_SIZE];
};

struct hash_tbl_node {
    char filename[FILENAME_LEN];
    unsigned char hash[INTE_HASH_SIZE];
    struct hlist_node node;
};

static DEFINE_HASHTABLE(inte_hash_table, INTE_HASH_BITS);
static rwlock_t hashtable_lock;
static rwlock_t ko_events_list_rwlock;
static rwlock_t systbl_events_list_rwlock;

/* __NR_syscalls 在 ARM64 未定义，使用 NR_syscalls */
#ifdef __NR_syscalls
#define SYS_CALL_TBL_SIZE  __NR_syscalls
#elif defined(NR_syscalls)
#define SYS_CALL_TBL_SIZE  NR_syscalls
#else
#error "Cannot determine syscall table size"
#endif

static unsigned long syscall_func_addr[SYS_CALL_TBL_SIZE] = {0};

#if CHECK_DEBUG
static unsigned long trigger_syscall_func_addr[SYS_CALL_TBL_SIZE] = {0};
#endif

uint8_t hash_syscall_table[SHA256_DIGEST_SIZE] = {0};

/* sys_call_table 通过 kallsyms 动态解析 */
static unsigned long *g_sys_call_table = NULL;

static struct delayed_work check_work;
static unsigned long check_interval = 60 * 60 * HZ;

static struct proc_dir_entry *proc_ko_entry;
static struct proc_dir_entry *proc_systbl_entry;
static struct proc_dir_entry *proc_status_entry;

static int total_entry_count = 0;
static uint8_t __ro_after_init hash_systbl_init[SHA256_DIGEST_SIZE] = {0};
static char *ko_events_list[MAX_EVENTS_COUNT] = {NULL};
static char *systbl_events_list[MAX_EVENTS_COUNT] = {NULL};
static int ko_event_count = 0;
static int systbl_event_count = 0;
static int boot_stage = 0;
static struct crypto_shash *g_sha256_tfm = NULL;
/***********************config(end)******************************/

/*
 * Elf_Ehdr / Elf_Shdr 在内核中实际叫 struct elfhdr / struct elf_shdr
 */
#ifndef Elf_Ehdr
typedef struct elfhdr Elf_Ehdr;
#endif
#ifndef Elf_Shdr
typedef struct elf_shdr Elf_Shdr;
#endif

/*
 * ============================================================
 * 4.19 内核的 struct load_info 布局
 * 请务必和你的内核源码 kernel/module.c 里的定义完全一致！
 * ============================================================
 */
struct load_info {
    const char *name;
    struct module *mod;
    Elf_Ehdr *hdr;
    unsigned long len;
    Elf_Shdr *sechdrs;
    char *secstrings, *strtab;
    unsigned long symoffs, stroffs, init_typeoffs, core_typeoffs;
    struct _ddebug *debug;
    unsigned int num_debug;
    bool sig_ok;
#ifdef CONFIG_KALLSYMS
    unsigned long mod_kallsyms_init_off;
#endif
    struct {
        unsigned int sym, str, mod, vers, info, pcpu;
    } index;
};

int add_ko_event(const char *event_str)
{
    int ret = 0;
    char *event_new_str;
    unsigned long flags;
    int i;

    if (!event_str) {
        pr_err("[KERNEL_SECURITY_CHECK]: add_ko_event [event_str] is NULL.\n");
        return -EINVAL;
    }
    event_new_str = kstrdup(event_str, GFP_ATOMIC);
    if (!event_new_str) {
        pr_err("[KERNEL_SECURITY_CHECK]:Failed to allocate memory for ko event string\n");
        return -ENOMEM;
    }
    write_lock_irqsave(&ko_events_list_rwlock, flags);
    if (ko_event_count >= MAX_EVENTS_COUNT) {
        pr_info("[KERNEL_SECURITY_CHECK]:ko Event list full (max [%d] events), replace the oldest event.\n", MAX_EVENTS_COUNT);
        kfree(ko_events_list[0]);
        for (i = 0; i < ko_event_count - 1; i++) {
            ko_events_list[i] = ko_events_list[i + 1];
        }
        ko_events_list[ko_event_count - 1] = event_new_str;
        goto out_unlock;
    } else {
        ko_events_list[ko_event_count] = event_new_str;
        ko_event_count++;
    }
out_unlock:
    write_unlock_irqrestore(&ko_events_list_rwlock, flags);
    pr_info("[KERNEL_SECURITY_CHECK]: Added ko event succeed.\n");
    return ret;
}

int add_systbl_event(const char *event_str)
{
    int ret = 0;
    char *event_new_str;
    unsigned long flags;
    int i;

    if (!event_str) {
        pr_err("[KERNEL_SECURITY_CHECK]: add_systbl_event [event_str] is NULL.\n");
        return -EINVAL;
    }
    event_new_str = kstrdup(event_str, GFP_ATOMIC);
    if (!event_new_str) {
        pr_err("[KERNEL_SECURITY_CHECK]:Failed to allocate memory for systbl event string\n");
        return -ENOMEM;
    }
    write_lock_irqsave(&systbl_events_list_rwlock, flags);
    if (systbl_event_count >= MAX_EVENTS_COUNT) {
        pr_info("[KERNEL_SECURITY_CHECK]:systbl Event list full (max [%d] events), replace the oldest event.\n", MAX_EVENTS_COUNT);
        kfree(systbl_events_list[0]);
        for (i = 0; i < systbl_event_count - 1; i++) {
            systbl_events_list[i] = systbl_events_list[i + 1];
        }
        systbl_events_list[systbl_event_count - 1] = event_new_str;
        goto out_unlock;
    } else {
        systbl_events_list[systbl_event_count] = event_new_str;
        systbl_event_count++;
    }
out_unlock:
    write_unlock_irqrestore(&systbl_events_list_rwlock, flags);
    pr_info("[KERNEL_SECURITY_CHECK]: Added systbl event succeed.\n");
    return ret;
}

static int do_hash(const void *data, unsigned int data_len, uint8_t *hash)
{
    int ret;
    SHASH_DESC_ON_STACK(desc, g_sha256_tfm);

    if (unlikely(IS_ERR_OR_NULL(g_sha256_tfm))) {
        pr_err_ratelimited("[KERNEL_SECURITY_CHECK]: SHA256 TFM not initialized\n");
        return -ENODEV;
    }
    if (unlikely(!data || !hash || !data_len)) {
        pr_err("[KERNEL_SECURITY_CHECK]: Invalid parameters for do_hash\n");
        return -EINVAL;
    }
    desc->tfm = g_sha256_tfm;
    ret = crypto_shash_digest(desc, (const u8 *)data, data_len, hash);
    if (unlikely(ret)) {
        pr_err("[KERNEL_SECURITY_CHECK]: crypto_shash_digest failed: %d\n", ret);
    }
    memzero_explicit(desc, sizeof(*desc) + crypto_shash_descsize(g_sha256_tfm));
    return ret;
}

/**************************syscallTBL check ********************/
static int get_timestamp_and_true(char *event_str, int len)
{
    struct timespec64 now;
    int ret = 0;
    long long milliseconds;

    if (event_str == NULL) {return -EFAULT;}
    ktime_get_real_ts64(&now);
    milliseconds = (long long)now.tv_sec * 1000LL + now.tv_nsec / 1000000;
    ret = snprintf(event_str, len, "%lld:true", milliseconds);
    if (ret < 0 || ret >= len) {
        pr_err("[KERNEL_SECURITY_CHECK]:Failed to format systbl event string.\n");
        return -EFAULT;
    }
    return 0;
}

static void check_task(struct work_struct *work)
{
    int ret = 0;
    char event_str[64];

    pr_info("[KERNEL_SECURITY_CHECK]:Performing hourly check...\n");
    if (READ_ONCE(boot_stage) != BOOT_COMPLETE) {
        pr_info("[KERNEL_SECURITY_CHECK]: system boot, skip syscallTbl hash check.");
        schedule_delayed_work(&check_work, check_interval);
        return;
    }
    if (!g_sys_call_table) {
        pr_err("[KERNEL_SECURITY_CHECK]: sys_call_table not resolved, skip.");
        goto reschedule;
    }
    memset(hash_syscall_table, 0xFF, sizeof(hash_syscall_table));
    ret = do_hash(g_sys_call_table, sizeof(syscall_func_addr), hash_syscall_table);
    if (ret != 0) {
        pr_err("[KERNEL_SECURITY_CHECK]:do hash for syscall_tbl failed.");
        goto reschedule;
    }
    if (memcmp(hash_syscall_table, hash_systbl_init, sizeof(hash_syscall_table)) != 0) {
        pr_info("[KERNEL_SECURITY_CHECK]:syscall_tbl maybe modified.");
        memset(event_str, 0, sizeof(event_str));
        if (get_timestamp_and_true(event_str, sizeof(event_str))) {
            pr_err("[KERNEL_SECURITY_CHECK]: get_timestamp_and_true failed.");
        } else {
            if (add_systbl_event(event_str)) {
                pr_err("[KERNEL_SECURITY_CHECK]: add_systbl_event failed.");
            }
        }
    }

reschedule:
    schedule_delayed_work(&check_work, check_interval);
}

#if CHECK_DEBUG
static void trigger_systbl_check_manual(void)
{
    int ret;
    char event_str[64];

    if (!g_sys_call_table) {
        pr_err("[KERNEL_SECURITY_CHECK]: sys_call_table not resolved.");
        return;
    }
    memset(hash_syscall_table, 0xFF, sizeof(hash_syscall_table));
    ret = do_hash(g_sys_call_table, sizeof(syscall_func_addr), hash_syscall_table);
    if (ret != 0) {
        pr_err("[KERNEL_SECURITY_CHECK]:[trigger_systbl_check_manual] do hash for syscall_tbl failed.");
    }
    if (memcmp(hash_syscall_table, hash_systbl_init, sizeof(hash_syscall_table)) != 0) {
        pr_info("[KERNEL_SECURITY_CHECK]:[trigger_systbl_check_manual] syscall_tbl maybe modified.");
        memset(event_str, 0, sizeof(event_str));
        if (get_timestamp_and_true(event_str, sizeof(event_str))) {
            pr_err("[KERNEL_SECURITY_CHECK]:[trigger_systbl_check_manual] get_timestamp_and_true failed.");
        } else {
            if (add_systbl_event(event_str)) {
                pr_err("[KERNEL_SECURITY_CHECK]:[trigger_systbl_check_manual] add_systbl_event failed.");
            }
        }
    }
}

static void trigger_systbl_modify_manual(void)
{
    int ret;
    char event_str[64];

    if (!g_sys_call_table) {
        pr_err("[KERNEL_SECURITY_CHECK]: sys_call_table not resolved.");
        return;
    }
    memset(hash_syscall_table, 0xFF, sizeof(hash_syscall_table));
    memcpy(trigger_syscall_func_addr, g_sys_call_table, sizeof(trigger_syscall_func_addr));
    trigger_syscall_func_addr[0] = (unsigned long)(0);
    ret = do_hash(trigger_syscall_func_addr, sizeof(trigger_syscall_func_addr), hash_syscall_table);
    if (ret != 0) {
        pr_err("[KERNEL_SECURITY_CHECK]:[trigger_systbl_modify_manual] do hash for syscall_tbl failed.");
    }
    if (memcmp(hash_syscall_table, hash_systbl_init, sizeof(hash_syscall_table)) != 0) {
        pr_info("[KERNEL_SECURITY_CHECK]:[trigger_systbl_modify_manual] syscall_tbl maybe modified.");
        memset(event_str, 0, sizeof(event_str));
        if (get_timestamp_and_true(event_str, sizeof(event_str))) {
            pr_err("[KERNEL_SECURITY_CHECK]:[trigger_systbl_modify_manual] get_timestamp_and_true failed.");
        } else {
            if (add_systbl_event(event_str)) {
                pr_err("[KERNEL_SECURITY_CHECK]:[trigger_systbl_modify_manual] add_systbl_event failed.");
            }
        }
    }
}
#endif

static void trigger_clean_event_manual(void)
{
    int i;
    unsigned long flags;

    write_lock_irqsave(&ko_events_list_rwlock, flags);
    for (i = 0; i < MAX_EVENTS_COUNT; i++) {
        if (ko_events_list[i] != NULL) {
            kfree(ko_events_list[i]);
            ko_events_list[i] = NULL;
        }
    }
    ko_event_count = 0;
    write_unlock_irqrestore(&ko_events_list_rwlock, flags);

    write_lock_irqsave(&systbl_events_list_rwlock, flags);
    for (i = 0; i < MAX_EVENTS_COUNT; i++) {
        if (systbl_events_list[i] != NULL) {
            kfree(systbl_events_list[i]);
            systbl_events_list[i] = NULL;
        }
    }
    systbl_event_count = 0;
    write_unlock_irqrestore(&systbl_events_list_rwlock, flags);
}
/****************************syscallTBL check(end) *************/

/***************************find ko name ***********************/
static char *next_tag_safe(char *string, unsigned long *secsize)
{
    unsigned long len = strnlen(string, *secsize);
    if (len == *secsize) {
        return NULL;
    }
    string += len + 1;
    *secsize -= (len + 1);
    while (*secsize > 0 && string[0] == 0) {
        string++;
        (*secsize)--;
    }
    if (*secsize == 0) {
        return NULL;
    }
    return string;
}

static char *get_modinfo_name_safe(const struct load_info *info)
{
    unsigned int i;
    char *p;
    const char *target = "name=";
    const size_t target_len = 5;

    Elf_Ehdr *hdr = info->hdr;
    Elf_Shdr *sechdrs, *strhdr;
    char *secstrings;
    int info_idx = -1;
    int count = 0;
    char *curr_name;
    char *modinfo;
    unsigned long size;

    if (!hdr || hdr->e_shnum == 0 || hdr->e_shstrndx >= hdr->e_shnum)
        return NULL;

    sechdrs = (void *)hdr + hdr->e_shoff;
    strhdr = &sechdrs[hdr->e_shstrndx];
    secstrings = (void *)hdr + strhdr->sh_offset;

    for (i = 1; i < hdr->e_shnum; i++) {
        if (sechdrs[i].sh_name >= strhdr->sh_size) {
            continue;
        }
        curr_name = secstrings + sechdrs[i].sh_name;
        if (curr_name[0] == '.' && strcmp(curr_name, ".modinfo") == 0) {
            count++;
            info_idx = i;
            if (count > 1) {
                return NULL;
            }
        }
    }
    if (count == 1) {
        modinfo = (char *)hdr + sechdrs[info_idx].sh_offset;
        size = sechdrs[info_idx].sh_size;
        for (p = modinfo; p; p = next_tag_safe(p, &size)) {
            if (size > target_len && memcmp(p, target, target_len) == 0) {
                return p + target_len;
            }
        }
    }
    return NULL;
}
/***************************find ko name（end）***********************/

/**********************************hash table search*********************************/
bool check_ko_exist_in_hash_tbl(const char *filename)
{
    u32 hash_key = jhash(filename, strlen(filename), 0);
    struct hash_tbl_node *entry;
    bool found = false;

    read_lock(&hashtable_lock);
    hash_for_each_possible(inte_hash_table, entry, node, hash_key) {
        if (strcmp(entry->filename, filename) == 0) {
            found = true;
            break;
        }
    }
    read_unlock(&hashtable_lock);
    return found;
}

bool check_ko_exist_in_hash_tbl_nolock(const char *filename)
{
    u32 hash_key = jhash(filename, strlen(filename), 0);
    struct hash_tbl_node *entry;

    hash_for_each_possible(inte_hash_table, entry, node, hash_key) {
        if (strcmp(entry->filename, filename) == 0) {
            return true;
        }
    }
    return false;
}

int find_hash_by_name(const char *filename, unsigned char *out_hash)
{
    u32 hash_key = jhash(filename, strlen(filename), 0);
    struct hash_tbl_node *entry;
    int ret = -ENOENT;

    if (!out_hash)
        return -EINVAL;

    read_lock(&hashtable_lock);
    hash_for_each_possible(inte_hash_table, entry, node, hash_key) {
        if (strcmp(entry->filename, filename) == 0) {
            memcpy(out_hash, entry->hash, INTE_HASH_SIZE);
            ret = 0;
            break;
        }
    }
    read_unlock(&hashtable_lock);
    return ret;
}
/**********************************hash table search(end)*************************************/

/***************************Hook entry******************************/
static int hash_probe_entry(struct kretprobe_instance *i, struct pt_regs *pr)
{
    int ret = 0;
    void *ptr;
    struct load_info *info;
    SHASH_DESC_ON_STACK(desc, g_sha256_tfm);
    uint8_t hash[INTE_HASH_SIZE] = {0};
    unsigned long remaining;
    void *mod;
    u64 start_ns;
    unsigned long chunk;
    char *ko_name;
    char ko_name_with_suffix[FILENAME_LEN + 5];
    unsigned char init_hash[INTE_HASH_SIZE];

    if (READ_ONCE(boot_stage) != BOOT_COMPLETE) {
        pr_info("[KERNEL_SECURITY_CHECK]: system boot, skip ko hash check.");
        return 0;
    }
    if (!pr) {
        return 0;
    }
    ptr = (void *)pr->regs[0];
    if (!ptr) {
        pr_err_ratelimited("[KERNEL_SECURITY_CHECK]: Invalid ptr: pr->regs[0]");
        return 0;
    }
    info = (struct load_info *)(ptr);
    if (!info || !info->hdr || !info->len) {
        pr_err_ratelimited("[KERNEL_SECURITY_CHECK]: Invalid load_info");
        return 0;
    }
    if (unlikely(IS_ERR_OR_NULL(g_sha256_tfm))) {
        pr_err_ratelimited("[KERNEL_SECURITY_CHECK]: SHA256 tfm not ready\n");
        return 0;
    }
    desc->tfm = g_sha256_tfm;
    ret = crypto_shash_init(desc);
    if (ret) {
        pr_err("[KERNEL_SECURITY_CHECK]: Failed to initialize desc...");
        goto out_clean_desc;
    }
    remaining = info->len;
    mod = info->hdr;
    start_ns = ktime_get_ns();
    while (remaining > 0) {
        chunk = min_t(unsigned long, remaining, CHUNK_SIZE);
        ret = crypto_shash_update(desc, mod, chunk);
        if (ret) {
            pr_err("[KERNEL_SECURITY_CHECK]: crypto_shash_update failed.\n");
            goto out_clean_desc;
        }
        mod += chunk;
        remaining -= chunk;
        if (unlikely((ktime_get_ns() - start_ns) > 100ULL * 1000 * 1000)) { // 100ms
            pr_err_ratelimited("[KERNEL_SECURITY_CHECK]: Checking timeout for large module!\n");
            goto out_clean_desc;
        }
    }
    ret = crypto_shash_final(desc, hash);
    pr_info("[KERNEL_SECURITY_CHECK]: Checking time is [%llu] ns!\n", ktime_get_ns() - start_ns);
    if (ret < 0) {
        pr_err("[KERNEL_SECURITY_CHECK]: Error: failed to compute hash!!!\n");
        goto out_clean_desc;
    }
    ko_name = get_modinfo_name_safe(info);
    if (ko_name == NULL) {
        pr_err("[KERNEL_SECURITY_CHECK]: get ko name failed.\n");
        goto out_clean_desc;
    }
    pr_info("[KERNEL_SECURITY_CHECK]: ko_name is [%s].", ko_name);
    scnprintf(ko_name_with_suffix, sizeof(ko_name_with_suffix), "%s.ko", ko_name);
    if (find_hash_by_name(ko_name_with_suffix, init_hash) != 0) {
        pr_info("[KERNEL_SECURITY_CHECK]: ko:[%s] hash not found, maybe unknown ko.", ko_name_with_suffix);
        if (add_ko_event(ko_name_with_suffix)) {
            pr_err("[KERNEL_SECURITY_CHECK]: ko events send failed. [%s]\n", ko_name_with_suffix);
        }
    } else if (memcmp(hash, init_hash, sizeof(hash)) != 0) {
        pr_info("[KERNEL_SECURITY_CHECK]: ko:[%s] hash diff, maybe modified ko.", ko_name_with_suffix);
        if (add_ko_event(ko_name_with_suffix)) {
            pr_err("[KERNEL_SECURITY_CHECK]: ko events send failed. [%s]\n", ko_name_with_suffix);
        }
    } else {
        pr_info("[KERNEL_SECURITY_CHECK]: ko [%s] hash verify succeed.", ko_name_with_suffix);
    }
out_clean_desc:
    memzero_explicit(desc, sizeof(*desc) + crypto_shash_descsize(g_sha256_tfm));
    return 0;
}
/***************************Hook entry(end)******************************/

static struct kretprobe hash_probe = {
    .entry_handler = hash_probe_entry,
    .maxactive = 100,
};

/**********************check sender***********************************/
static bool is_valid_sender(void)
{
    struct task_struct *task = current;
    const char *expected_process = "oplus_kohashpro";
    uint32_t euid;

    if (strcmp(task->comm, expected_process) != 0) {
        pr_err("[KERNEL_SECURITY_CHECK]:Invalid process: %s (expected: %s)\n", task->comm, expected_process);
        return false;
    }
    euid = __kuid_val(current->cred->euid);
    if (euid != 1000) {
        pr_err("[KO_INTEGRITY_VERI]:Invalid user, euid : [%u] \n", euid);
        return false;
    }
    return true;
}

static bool is_system_or_root_sender(void)
{
    uint32_t euid = __kuid_val(current->cred->euid);
    if (euid != 1000 && euid != 0) {
        pr_err("[KO_INTEGRITY_VERI]:Invalid user, euid : [%u] \n", euid);
        return false;
    }
    return true;
}
/**********************check sender（end）***********************************/

/********************** proc config********************************/
static int ko_proc_show(struct seq_file *m, void *v)
{
    int i;
    read_lock(&ko_events_list_rwlock);
    for (i = 0; i < MAX_EVENTS_COUNT; i++) {
        if (ko_events_list[i] == NULL) {
            break;
        }
        seq_printf(m, "%s\n", ko_events_list[i]);
    }
    read_unlock(&ko_events_list_rwlock);
    return 0;
}

static int systbl_proc_show(struct seq_file *m, void *v)
{
    int i;
    read_lock(&systbl_events_list_rwlock);
    for (i = 0; i < MAX_EVENTS_COUNT; i++) {
        if (systbl_events_list[i] == NULL) {
            break;
        }
        seq_printf(m, "%s\n", systbl_events_list[i]);
    }
    read_unlock(&systbl_events_list_rwlock);
    return 0;
}

static int proc_open_ko(struct inode *inode, struct file *file)
{
    return single_open(file, ko_proc_show, NULL);
}

static int proc_open_systbl(struct inode *inode, struct file *file)
{
    return single_open(file, systbl_proc_show, NULL);
}

void normalize_mod_name(char *name)
{
    if (!name) {
        return;
    }
    for (; *name; name++) {
        if (*name == '-')
            *name = '_';
    }
}

static ssize_t proc_write_ko(struct file *file, const char __user *buffer, size_t count, loff_t *ppos)
{
    struct hash_entry *input_data = NULL;
    char *event_buf = NULL;
    struct hash_tbl_node *entry = NULL;
    u32 header_val;
    int ko_event_len;
    int i;
    int ret = count;
    int num_entries;
    u32 key;
    u32 bucket;

    if (!is_valid_sender()) {
        pr_err("[KERNEL_SECURITY_CHECK]: Invalid sender process\n");
        return -EACCES;
    }
    if (count < sizeof(u32)) {
        return -EINVAL;
    }
    if (copy_from_user(&header_val, buffer, sizeof(u32))) {
        return -EFAULT;
    }

    if (header_val == KO_EVENT_FLAG) {
        if (count < sizeof(u32) * 2)
            return -EINVAL;
        if (copy_from_user(&ko_event_len, buffer + sizeof(u32), sizeof(int)))
            return -EFAULT;
        if (ko_event_len <= 0 || (size_t)ko_event_len > count - sizeof(u32) * 2) {
            pr_err("[KERNEL_SECURITY_CHECK]: Invalid event length: %d\n", ko_event_len);
            return -EINVAL;
        }
        event_buf = kzalloc(ko_event_len + 1, GFP_KERNEL);
        if (!event_buf)
            return -ENOMEM;
        if (copy_from_user(event_buf, buffer + sizeof(u32) * 2, ko_event_len)) {
            kfree(event_buf);
            return -EFAULT;
        }
        add_ko_event(event_buf);
        kfree(event_buf);
        return count;
    }

    num_entries = (int)header_val;
    if (num_entries <= 0 || num_entries > MAX_ENTRIES) {
        pr_err("[KERNEL_SECURITY_CHECK]: Invalid number of entries: %d\n", num_entries);
        return -EINVAL;
    }
    if (count < sizeof(u32) + (size_t)num_entries * sizeof(struct hash_entry)) {
        pr_err("[KERNEL_SECURITY_CHECK]: Input size too small for entries\n");
        return -EINVAL;
    }
    input_data = kmalloc_array(num_entries, sizeof(struct hash_entry), GFP_KERNEL);
    if (!input_data) {
        pr_err("[KERNEL_SECURITY_CHECK]: Failed to allocate memory for input_data\n");
        return -ENOMEM;
    }
    if (copy_from_user(input_data, buffer + sizeof(u32), num_entries * sizeof(struct hash_entry))) {
        pr_err("[KERNEL_SECURITY_CHECK]: Failed to copy data from user\n");
        kfree(input_data);
        return -EFAULT;
    }
    for (i = 0; i < num_entries; i++) {
        entry = kmalloc(sizeof(struct hash_tbl_node), GFP_KERNEL);
        if (!entry) {
            ret = -ENOMEM;
            goto out_free_input;
        }
        INIT_HLIST_NODE(&entry->node);
        strscpy(entry->filename, input_data[i].filename, FILENAME_LEN);
        normalize_mod_name(entry->filename);
        memcpy(entry->hash, input_data[i].hash, INTE_HASH_SIZE);
        key = jhash(entry->filename, strlen(entry->filename), 0);
        bucket = hash_min(key, INTE_HASH_BITS);
        write_lock(&hashtable_lock);
        if (check_ko_exist_in_hash_tbl_nolock(entry->filename)) {
            write_unlock(&hashtable_lock);
            kfree(entry);
            continue;
        }
        hlist_add_head(&entry->node, &inte_hash_table[bucket]);
        total_entry_count++;
        write_unlock(&hashtable_lock);
        pr_info("[KERNEL_SECURITY_CHECK]: Added: %s\n", entry->filename);
    }
    pr_info("[KERNEL_SECURITY_CHECK]: Processed [%d] entries. Total in table: [%d]\n", num_entries, total_entry_count);
out_free_input:
    kfree(input_data);
    return ret;
}

static ssize_t proc_write_systbl(struct file *file, const char __user *buffer, size_t count, loff_t *ppos)
{
#if CHECK_DEBUG
    char flag;
    if (!is_system_or_root_sender()) {
        pr_err("[KERNEL_SECURITY_CHECK]:Invalid sender process\n");
        return -EACCES;
    }
    if (count < sizeof(char) || copy_from_user(&flag, buffer, sizeof(char))) {
        pr_err("[KERNEL_SECURITY_CHECK]:Failed to copy systbl echo flag.\n");
        return -EFAULT;
    }
    pr_info("[KERNEL_SECURITY_CHECK]:flag is :[%c].\n", flag);
    if (flag == '0') {
        trigger_systbl_check_manual();
    }
    if (flag == '1') {
        trigger_systbl_modify_manual();
    }
    if (flag == '2') {
        trigger_clean_event_manual();
    }
#endif
    return count;
}

static ssize_t proc_write_status(struct file *file, const char __user *buffer, size_t count, loff_t *ppos)
{
    int status = -1;
    if (!is_system_or_root_sender()) {
        pr_err("[KERNEL_SECURITY_CHECK]:Invalid sender process\n");
        return -EACCES;
    }
    if (count < sizeof(int)) {
        pr_err("[KERNEL_SECURITY_CHECK]:Invalid buffer size\n");
        return -EINVAL;
    }
    if (copy_from_user(&status, buffer, sizeof(int))) {
        pr_err("[KERNEL_SECURITY_CHECK]:Failed to copy status.\n");
        return -EFAULT;
    }
    if (status == BOOT_COMPLETE) {
        WRITE_ONCE(boot_stage, status);
    }
    return count;
}
/**********************proc config(end)**************************/

/********************** file_operations (Compatible with Linux 4.19) ******************************/
static const struct file_operations proc_fops_ko = {
    .owner   = THIS_MODULE,
    .open    = proc_open_ko,
    .read    = seq_read,
    .llseek  = seq_lseek,
    .release = single_release,
    .write   = proc_write_ko,
};

static const struct file_operations proc_fops_systbl = {
    .owner   = THIS_MODULE,
    .open    = proc_open_systbl,
    .read    = seq_read,
    .llseek  = seq_lseek,
    .release = single_release,
    .write   = proc_write_systbl,
};

static const struct file_operations proc_fops_status = {
    .owner   = THIS_MODULE,
    .open    = simple_open,
    .write   = proc_write_status,
};
/********************** file_operations(end) **************************/

/*
 * 通过 kallsyms_lookup_name 动态解析 sys_call_table
 * 4.19 上 kallsyms_lookup_name 是 EXPORT_SYMBOL_GPL 的，可以直接调用
 */
static int resolve_sys_call_table(void)
{
    unsigned long addr;

    addr = kallsyms_lookup_name("sys_call_table");
    if (!addr) {
        pr_err("[KERNEL_SECURITY_CHECK]: Cannot find sys_call_table\n");
        return -ENOENT;
    }
    g_sys_call_table = (unsigned long *)addr;
    pr_info("[KERNEL_SECURITY_CHECK]: sys_call_table @ 0x%lx\n", addr);
    return 0;
}

static int __init ko_integrity_init(void)
{
    int ret = 0;

    rwlock_init(&hashtable_lock);
    rwlock_init(&ko_events_list_rwlock);
    rwlock_init(&systbl_events_list_rwlock);

    proc_ko_entry = proc_create("inte_ko", 0664, NULL, &proc_fops_ko);
    if (!proc_ko_entry) {
        pr_err("[KERNEL_SECURITY_CHECK]: Failed to create /proc/inte_ko\n");
        return -ENOMEM;
    }
    proc_set_user(proc_ko_entry, KUIDT_INIT(0), KGIDT_INIT(0));

    proc_systbl_entry = proc_create("inte_systbl", 0664, NULL, &proc_fops_systbl);
    if (!proc_systbl_entry) {
        pr_err("[KERNEL_SECURITY_CHECK]: Failed to create /proc/inte_systbl\n");
        ret = -ENOMEM;
        goto proc_failed;
    }
    proc_set_user(proc_systbl_entry, KUIDT_INIT(0), KGIDT_INIT(0));

    proc_status_entry = proc_create("inte_status", 0660, NULL, &proc_fops_status);
    if (!proc_status_entry) {
        ret = -ENOMEM;
        pr_err("[KERNEL_SECURITY_CHECK]: Failed to create /proc/inte_status\n");
        goto proc_failed;
    }
    proc_set_user(proc_status_entry, KUIDT_INIT(0), KGIDT_INIT(0));

    pr_info("[KERNEL_SECURITY_CHECK]: create /proc/inte_* succeed \n");

    hash_probe.kp.symbol_name = "load_module";
    ret = register_kretprobe(&hash_probe);
    if (ret < 0) {
        pr_err("[KERNEL_SECURITY_CHECK]: hash_probe register failed ! ret=%d\n", ret);
        goto proc_failed;
    }

    g_sha256_tfm = crypto_alloc_shash("sha256", 0, 0);
    if (IS_ERR(g_sha256_tfm)) {
        pr_err("[KERNEL_SECURITY_CHECK]: Failed to allocate sha256 tfm.\n");
        ret = PTR_ERR(g_sha256_tfm);
        g_sha256_tfm = NULL;
        goto init_failed;
    }

    ret = resolve_sys_call_table();
    if (ret) {
        goto init_failed;
    }

    memcpy(syscall_func_addr, g_sys_call_table, sizeof(syscall_func_addr));
    ret = do_hash(syscall_func_addr, sizeof(syscall_func_addr), hash_systbl_init);
    if (ret == 0) {
        pr_info("[KERNEL_SECURITY_CHECK]: init hash for syscall_tbl succeed.");
    } else {
        pr_err("[KERNEL_SECURITY_CHECK]: init hash for syscall_tbl failed.");
        goto init_failed;
    }

    INIT_DELAYED_WORK(&check_work, check_task);
    schedule_delayed_work(&check_work, check_interval);
    hash_init(inte_hash_table);
    pr_info("[KERNEL_SECURITY_CHECK]:init success! , version :0.18\n");
    return ret;

init_failed:
    if (g_sha256_tfm && !IS_ERR(g_sha256_tfm)) {
        crypto_free_shash(g_sha256_tfm);
        g_sha256_tfm = NULL;
    }
    unregister_kretprobe(&hash_probe);
proc_failed:
    if (proc_ko_entry) { remove_proc_entry("inte_ko", NULL); proc_ko_entry = NULL; }
    if (proc_systbl_entry) { remove_proc_entry("inte_systbl", NULL); proc_systbl_entry = NULL; }
    if (proc_status_entry) { remove_proc_entry("inte_status", NULL); proc_status_entry = NULL; }
    return ret;
}

static void __exit ko_integrity_exit(void)
{
    int i;
    struct hash_tbl_node *entry;
    struct hlist_node *tmp;

    cancel_delayed_work_sync(&check_work);
    unregister_kretprobe(&hash_probe);

    if (g_sha256_tfm && !IS_ERR(g_sha256_tfm)) {
        crypto_free_shash(g_sha256_tfm);
        g_sha256_tfm = NULL;
    }

    write_lock(&hashtable_lock);
    hash_for_each_safe(inte_hash_table, i, tmp, entry, node) {
        hash_del(&entry->node);
        kfree(entry);
        total_entry_count--;
    }
    write_unlock(&hashtable_lock);

    trigger_clean_event_manual();

    if (proc_ko_entry) remove_proc_entry("inte_ko", NULL);
    if (proc_systbl_entry) remove_proc_entry("inte_systbl", NULL);
    if (proc_status_entry) remove_proc_entry("inte_status", NULL);
    pr_info("[KERNEL_SECURITY_CHECK]: exit success!");
}

module_init(ko_integrity_init);
module_exit(ko_integrity_exit);
MODULE_LICENSE("GPL");
MODULE_AUTHOR("cenjun");
MODULE_DESCRIPTION("Kernel integrity check: syscall table & ko hash");
