/*
 * bintrans.h
 *
 * bintrans
 *
 * Copyright (C) 2001,2002 Mark Probst
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
 */

#include <sys/types.h>
#include <unistd.h>

#include "config_defs.h"
#include "target_arch.h"
#include "emu_arch.h"

#define bt_assert(expr)                                             \
  ((void) ((expr) ? 0 :                                             \
           bt_assert_fail (#expr,                                   \
                            __FILE__, __LINE__,                     \
                            __PRETTY_FUNCTION__), 0))

void bt_assert_fail (char* expr, char* file, int line, char* fn) __attribute__ ((__noreturn__));

word_32 leading_zeros (word_32);
word_1 parity_even (word_32 op);
word_32 rotl_32 (word_32 x, word_32 i);
word_16 rotl_16 (word_16 x, word_32 i);
word_32 mask_32 (word_32 begin, word_32 end);
word_64 mask_64 (word_32 begin, word_32 end);
word_32 maskmask (word_32 width, word_32 num, word_32 mask);
word_32 addcarry_32 (word_32 op1, word_32 op2);
word_32 addcarry_16 (word_16 op1, word_16 op2);
word_32 addcarry_8 (word_8 op1, word_8 op2);
word_32 subcarry_32 (word_32 op1, word_32 op2);
word_32 subcarry_16 (word_16 op1, word_16 op2);
word_32 subcarry_8 (word_8 op1, word_8 op2);
word_32 addoverflow_32 (word_32 op1, word_32 op2);
word_32 addoverflow_16 (word_16 op1, word_16 op2);
word_32 addoverflow_8 (word_8 op1, word_8 op2);

int can_inv_maskmask (int width, word_64 value);
word_64 inv_maskmask (int width, word_64 value);

/* asm routines */
void flush_icache (addr_t first, addr_t last);
void start_execution (addr_t);

/* these asm routines are only called from generated code */
void direct_dispatcher (void);
void indirect_dispatcher (void);
void system_call_entry (void);
void c_stub (void);
void isync_entry (void);
#ifdef ARCH_PPC
void interpreter_handle (void);
void repe_cmpsb_entry (void);
void rep_movsb_entry (void);
void rep_movsd_entry (void);
void repne_scasb_entry (void);
void rep_stosb_entry (void);
void rep_stosd_entry (void);
#endif

#define PAGE_READABLE         1
#define PAGE_WRITEABLE        2
#define PAGE_EXECUTABLE       4
#define PAGE_MMAPPED          8

#define PAGE_PROT_MASK        7

#define PAGE_EMU_FLAGS(f)          ((f) & 15)
#define PAGE_NATIVE_FLAGS(f)       (((f) >> 4) & 15)

#define PAGE_SET_EMU_FLAGS(f,n)    (((f) & ~15) | (n))
#define PAGE_SET_NATIVE_FLAGS(f,n) (((f) & ~(15 << 4)) | ((n) << 4))

#define LEVEL1_SIZE      1024
#define LEVEL1_SHIFT       22
#define LEVEL1_MASK     0x3ff
#define LEVEL1_INDEX(a)     (((a) >> LEVEL1_SHIFT) & LEVEL1_MASK)

#define LEVEL2_SIZE      1024
#define LEVEL2_SHIFT       12
#define LEVEL2_MASK     0x3ff
#define LEVEL2_INDEX(a)     (((a) >> LEVEL2_SHIFT) & LEVEL2_MASK)

#define PPC_PAGE_SIZE    4096
#define PPC_PAGE_SHIFT     12
#define PPC_PAGE_MASK   0xfff

#define PPC_PAGE_ALIGN(a)      (((a)+PPC_PAGE_SIZE-1)&~PPC_PAGE_MASK)
#define PPC_PAGE_ALIGN_DOWN(a) ((a)&~PPC_PAGE_MASK)

#if defined(EMU_PPC)
#define MMAP_START 0x30000000
#elif defined(EMU_I386)
#define MMAP_START 0x40000000
#endif

typedef struct
{
    int flags;
    byte *mem;
} page_t;

typedef struct _breakpoint_t
{
    word_32 addr;
    struct _breakpoint_t *next;
} breakpoint_t;

typedef struct _watchpoint_t
{
    word_32 addr;
    word_32 len;
    struct _watchpoint_t *next;
} watchpoint_t;

typedef struct
{
    int free;
    int native_fd;
} fd_mapping_t;

#define MAX_FDS      1024

typedef struct
{
    int direct_memory;
    word_32 data_segment_top;
    unsigned long insn_count;
    int halt;
    int have_jumped;
    int have_syscalled;
    int trace;
    breakpoint_t *breakpoints;
    watchpoint_t *watchpoints;
    EMU_REGISTER_SET;
    word_32 pc;
    page_t *pagetable[LEVEL1_SIZE];
    fd_mapping_t fd_map[MAX_FDS];
} interpreter_t;

typedef unsigned long trace_count_t;

#ifdef CROSSDEBUGGER
#define MAX_MEM_TRACES         65536

typedef struct
{
    word_32 addr;
    word_32 len;
} mem_write_t;

extern int trace_mem;
extern int num_mem_trace_entries;
extern mem_write_t mem_trace[MAX_MEM_TRACES];

void reset_mem_trace (void);
int compare_mem_writes (interpreter_t *intp1, interpreter_t *intp2);
#endif

#define MAX_TRACE_JUMPS     6
#define MAX_TRACE_BLOCKS    (MAX_TRACE_JUMPS + 1)

#if defined(NEED_COMPILER) && MAX_TRACE_JUMPS != 6
#error max trace jumps must be 6 for assembler
#endif

#define swap_16(x)           (((word_16)(x) >> 8) | (((word_16)(x) & 0xff) << 8))
#define swap_32(x)           (((word_32)swap_16((x)) << 16) | (word_32)swap_16((word_32)(x) >> 16))

#define SEX16(x,w)  ((((x)&(1<<((w)-1))) ? ((0xffff<<(w))|(x)) : (x)) & 0xffff)
#define SEX32(x,w)  (((x)&(1<<((w)-1))) ? ((0xffffffff<<(w))|(x)) : (x))

#define DIRECT_MEM_BASE     0x000000000
#define REAL_ADDR(a)        ((addr_t)(a) + DIRECT_MEM_BASE)

#ifdef SWAP_DIRECT_MEM
#define direct_mem_set_32(addr,value)  (*(word_32*)REAL_ADDR(addr) = swap_32(value))
#define direct_mem_get_32(addr)        swap_32(*(word_32*)REAL_ADDR(addr))
#else
#define direct_mem_set_32(addr,value)  (*(word_32*)REAL_ADDR(addr) = (value))
#define direct_mem_get_32(addr)        (*(word_32*)REAL_ADDR(addr))
#endif

#ifdef DIFFERENT_BYTEORDER
#ifdef SWAP_DIRECT_MEM
#define direct_mem_set_8(addr,value)   (*(byte*)REAL_ADDR(addr) = (value))
#define direct_mem_set_16(addr,value)  (*(word_16*)REAL_ADDR(addr) = swap_16(value))
#define direct_mem_get_8(addr)         (*(byte*)REAL_ADDR(addr))
#define direct_mem_get_16(addr)        swap_16(*(word_16*)REAL_ADDR(addr))
#else
#define direct_mem_set_8(addr,value)   (*(byte*)REAL_ADDR((addr) ^ 3) = (value))
#define direct_mem_set_16(addr,value)  (*(word_16*)REAL_ADDR((addr) ^ 2) = (value))
#define direct_mem_get_8(addr)         (*(byte*)REAL_ADDR((addr) ^ 3))
#define direct_mem_get_16(addr)        (*(word_16*)REAL_ADDR((addr) ^ 2))
#endif
#else
#define direct_mem_set_8(addr,value)   (*(byte*)REAL_ADDR(addr) = (value))
#define direct_mem_set_16(addr,value)  (*(word_16*)REAL_ADDR(addr) = (value))
#define direct_mem_get_8(addr)         (*(byte*)REAL_ADDR(addr))
#define direct_mem_get_16(addr)        (*(word_16*)REAL_ADDR(addr))
#endif

#ifdef EMU_BIG_ENDIAN
#define direct_mem_set_64(addr,value)  ({ word_32 a = (addr); word_64 v = (value); direct_mem_set_32(a, v >> 32); direct_mem_set_32(a + 4, v & 0xffffffff); })
#define direct_mem_get_64(addr)        ({ word_32 a = (addr); ((word_64)direct_mem_get_32(a) << 32) | direct_mem_get_32(a + 4); })
#else
#define direct_mem_set_64(addr,value)  ({ word_32 a = (addr); word_64 v = (value); direct_mem_set_32(a, v & 0xffffffff); direct_mem_set_32(a + 4, v >> 32); })
#define direct_mem_get_64(addr)        ({ word_32 a = (addr); ((word_64)direct_mem_get_32(a + 4) << 32) | direct_mem_get_32(a); })
#endif

void emulated_mem_set_8 (interpreter_t *intp, word_32 addr, word_32 value);
void emulated_mem_set_16 (interpreter_t *intp, word_32 addr, word_16 value);
void emulated_mem_set_32 (interpreter_t *intp, word_32 addr, word_32 value);
void emulated_mem_set_64 (interpreter_t *intp, word_32 addr, word_64 value);
word_8 emulated_mem_get_8 (interpreter_t *intp, word_32 addr);
word_16 emulated_mem_get_16 (interpreter_t *intp, word_32 addr);
word_32 emulated_mem_get_32 (interpreter_t *intp, word_32 addr);
word_64 emulated_mem_get_64 (interpreter_t *intp, word_32 addr);

#define mem_set_8(intp,addr,value)     ((intp)->direct_memory ? direct_mem_set_8((addr),(value)) : emulated_mem_set_8((intp),(addr),(value)))
#define mem_set_16(intp,addr,value)    ((intp)->direct_memory ? direct_mem_set_16((addr),(value)) : emulated_mem_set_16((intp),(addr),(value)))
#define mem_set_32(intp,addr,value)    ((intp)->direct_memory ? direct_mem_set_32((addr),(value)) : emulated_mem_set_32((intp),(addr),(value)))
#define mem_set_64(intp,addr,value)    ((intp)->direct_memory ? direct_mem_set_64((addr),(value)) : emulated_mem_set_64((intp),(addr),(value)))
#define mem_get_8(intp,addr)           ((intp)->direct_memory ? direct_mem_get_8((addr)) : emulated_mem_get_8((intp),addr))
#define mem_get_16(intp,addr)          ((intp)->direct_memory ? direct_mem_get_16((addr)) : emulated_mem_get_16((intp),(addr)))
#define mem_get_32(intp,addr)          ((intp)->direct_memory ? direct_mem_get_32((addr)) : emulated_mem_get_32((intp),(addr)))
#define mem_get_64(intp,addr)          ((intp)->direct_memory ? direct_mem_get_64((addr)) : emulated_mem_get_64((intp),(addr)))

word_16 mem_get_16_unaligned (interpreter_t *intp, word_32 addr);
word_32 mem_get_32_unaligned (interpreter_t *intp, word_32 addr);

ssize_t read_all (int fd, byte *buf, size_t count);
ssize_t read_all_at (int fd, byte *buf, size_t count, off_t offset);

word_32 copy_file_to_mem (interpreter_t *intp, int fd, word_32 addr, word_32 len, word_32 offset, int reset);
int prot_to_flags (int prot);
void mprotect_pages (interpreter_t *intp, word_32 addr, word_32 len, int flags, int add, int zero);
void natively_mprotect_pages (interpreter_t *intp, word_32 addr, word_32 len);
void natively_mprotect_pages_with_flags (interpreter_t *intp, word_32 addr, word_32 len, int flags);
word_32 mmap_anonymous (interpreter_t *intp, word_32 len, int flags, int fixed, word_32 addr);
word_32 mmap_file (interpreter_t *intp, word_32 len, int flags, int fixed, word_32 addr, int fd, word_32 offset);
int is_mapped (interpreter_t *intp, word_32 addr, word_32 len, int *flags);
int is_unmapped (interpreter_t *intp, word_32 addr, word_32 len);
int mem_flags_union (interpreter_t *intp, word_32 mem_start, word_32 mem_len);

void mem_copy_to_user_8 (interpreter_t *intp, word_32 addr, byte *buf, word_32 len);
void mem_copy_from_user_8 (interpreter_t *intp, byte *buf, word_32 addr, word_32 len);
void mem_copy_to_user_32 (interpreter_t *intp, word_32 addr, byte *buf, word_32 len);
void mem_copy_from_user_32 (interpreter_t *intp, byte *buf, word_32 addr, word_32 len);
word_32 copy_string (interpreter_t *intp, char *str, word_32 p);
word_32 copy_strings (interpreter_t *intp, int num, char **strs, word_32 p);
word_32 strlen_user (interpreter_t *intp, word_32 p);
char* strdup_from_user (interpreter_t *intp, word_32 p);
void strcpy_to_user (interpreter_t *intp, word_32 p, char *s);

#ifdef CROSSDEBUGGER
#define sc_open_fd(i,f) \
  ({ int __fd1 = open_fd(debugger_intp, (f)), __fd2 = open_fd(compiler_intp, (f)); \
     bt_assert(__fd1 == __fd2); \
     __fd1; })
#define sc_close_fd(i,f) \
  (close_fd(debugger_intp, (f)), close_fd(compiler_intp, (f)))
#define sc_mem_set_8(i,a,v) \
  (mem_set_8(debugger_intp, (a), (v)), mem_set_8(compiler_intp, (a), (v)))
#define sc_mem_set_16(i,a,v) \
  (mem_set_16(debugger_intp, (a), (v)), mem_set_16(compiler_intp, (a), (v)))
#define sc_mem_set_32(i,a,v) \
  (mem_set_32(debugger_intp, (a), (v)), mem_set_32(compiler_intp, (a), (v)))
#define sc_mem_set_64(i,a,v) \
  (mem_set_64(debugger_intp, (a), (v)), mem_set_64(compiler_intp, (a), (v)))
#define sc_mem_copy_to_user_8(i,a,n,l) \
  (mem_copy_to_user_8(debugger_intp, (a), (n), (l)), mem_copy_to_user_8(compiler_intp, (a), (n), (l)))
#define sc_strcpy_to_user(i,a,v) \
  (strcpy_to_user(debugger_intp, (a), (v)), strcpy_to_user(compiler_intp, (a), (v)))
#define sc_mmap_anonymous(i,l,fl,fi,a) \
  ({ word_32 __a1 = mmap_anonymous(debugger_intp, (l), (fl), (fi), (a)); \
     word_32 __a2 = mmap_anonymous(compiler_intp, (l), (fl), (fi), (a)); \
     bt_assert(__a1 == __a2); \
     __a1; })
#define sc_mmap_file(i,l,fl,fi,a,fd,o) \
  ({ word_32 __a1 = mmap_file(debugger_intp, (l), (fl), (fi), (a), (fd), (o)); \
     word_32 __a2 = mmap_file(compiler_intp, (l), (fl), (fi), (a), (fd), (o)); \
     bt_assert(__a1 == __a2); \
     __a1; })
#define sc_mprotect_pages(i,a,l,fl,ad,z) \
  (mprotect_pages(debugger_intp, (a), (l), (fl), (ad), (z)), mprotect_pages(compiler_intp, (a), (l), (fl), (ad), (z)))
#define sc_natively_mprotect_pages(i,a,l) \
  (natively_mprotect_pages(debugger_intp, (a), (l)), natively_mprotect_pages(compiler_intp, (a), (l)))
#define sc_set_data_segment_top(i,t) \
  ((debugger_intp->data_segment_top = (t)), (compiler_intp->data_segment_top = (t)))
#else
#define sc_open_fd(i,f)                   (open_fd((i),(f)))
#define sc_close_fd(i,f)                  (close_fd((i),(f)))
#define sc_mem_set_8(i,a,v)               (mem_set_8((i),(a),(v)))
#define sc_mem_set_16(i,a,v)              (mem_set_16((i),(a),(v)))
#define sc_mem_set_32(i,a,v)              (mem_set_32((i),(a),(v)))
#define sc_mem_set_64(i,a,v)              (mem_set_64((i),(a),(v)))
#define sc_mem_copy_to_user_8(i,a,n,l)    (mem_copy_to_user_8((i),(a),(n),(l)))
#define sc_strcpy_to_user(i,a,v)          (strcpy_to_user((i),(a),(v)))
#define sc_mmap_anonymous(i,l,fl,fi,a)    (mmap_anonymous((i),(l),(fl),(fi),(a)))
#define sc_mmap_file(i,l,fl,fi,a,fd,o)    (mmap_file((i),(l),(fl),(fi),(a),(fd),(o)))
#define sc_mprotect_pages(i,a,l,fl,ad,z)  (mprotect_pages((i),(a),(l),(fl),(ad),(z)))
#define sc_natively_mprotect_pages(i,a,l) (natively_mprotect_pages((i),(a),(l)))
#define sc_set_data_segment_top(i,t)      ((i)->data_segment_top = (t))
#endif

void handle_system_call (interpreter_t *intp);

void init_compiler (interpreter_t *intp, interpreter_t *dbg_intp);
void start_compiler (word_32 addr);
void print_compiler_stats (void);

extern char *insn_names[];

/* these come from ppc_compiler.c */
void move_ppc_regs_interpreter_to_compiler (interpreter_t *intp);
void move_ppc_regs_compiler_to_interpreter (interpreter_t *intp);

/* these are from ppc_interpreter.c */
void interpret_ppc_insn (interpreter_t *intp);
void dump_ppc_registers (interpreter_t *intp);
void disassemble_ppc_insn (word_32 insn, word_32 addr);

/* from i386.c */
void interpret_i386_insn (interpreter_t *intp);
void disassemble_i386_insn (interpreter_t *intp);
void liveness_i386_insn (interpreter_t *intp, word_32 *live, word_32 *killed);
void jump_analyze_i386_insn (interpreter_t *intp, int *_num_targets, word_32 *targets, int *can_fall_through, int *can_jump_indirectly);
void dump_i386_registers (interpreter_t *intp);
void setup_i386_registers (interpreter_t *intp, word_32 stack_bottom);

/* from i386_compiler.c */
void move_i386_regs_interpreter_to_compiler (interpreter_t *intp);
void move_i386_regs_compiler_to_interpreter (interpreter_t *intp);

/* from unaligned.c */
void init_unaligned (void);

/* from loops.c */
#ifdef COMPILER_THRESHOLD
word_64 loop_profiler (interpreter_t *intp, word_32 addr);
#else
void loop_profiler (interpreter_t *intp);
#endif
#ifdef DYNAMO_TRACES
void dynamo_profiler (interpreter_t *intp);
word_64 dynamo_runner (word_32 addr);
void print_trace_stats (void);
#endif
void print_loop_stats (void);
void init_loops (void);

#if defined(EMU_PPC)
#define interpret_insn                        interpret_ppc_insn
#define dump_registers                        dump_ppc_registers
#define setup_registers                       setup_ppc_registers
#define move_regs_interpreter_to_compiler     move_ppc_regs_interpreter_to_compiler
#define move_regs_compiler_to_interpreter     move_ppc_regs_compiler_to_interpreter
#elif defined(EMU_I386)
#define interpret_insn       interpret_i386_insn
#define dump_registers       dump_i386_registers
#define setup_registers      setup_i386_registers
#define move_regs_interpreter_to_compiler     move_i386_regs_interpreter_to_compiler
#define move_regs_compiler_to_interpreter     move_i386_regs_compiler_to_interpreter
#else
#error no interpreter specified
#endif

#if defined(ARCH_ALPHA)
#define disassemble_target_insn               disassemble_alpha_insn
#elif defined(ARCH_PPC)
#define disassemble_target_insn               disassemble_ppc_insn
#else
#define disassemble_target_insn               bt_assert(0),
#endif
