.text
.global _start
.type _start, %function

/*
 * Send EPONOAM_CMD_TYPE_UPDATACFG to the stock epon_oam command queue.
 *
 * libepon.h defines the queue as ftok(EPONOAM_MQ_FLAG_PATH, 10) and the
 * update-config command as 24.  This target has no msgsnd/ftok utility, so
 * use the Linux AArch64 syscalls directly.  Linux ftok() uses the low 16
 * inode bits, low 8 device bits, and the project id in bits 24..31.
 */
.equ AT_FDCWD, -100
.equ OPENAT_NR, 56
.equ CLOSE_NR, 57
.equ FSTAT_NR, 80
.equ MSGGET_NR, 186
.equ MSGSND_NR, 189
.equ EXIT_NR, 93
.equ EPONOAM_PROJID, 10
.equ EPONOAM_CMD_TYPE_UPDATACFG, 24

_start:
    /* Open and stat the queue marker used by the vendor's ftok(). */
    mov     x0, #AT_FDCWD
    adrp    x1, queue_path
    add     x1, x1, :lo12:queue_path
    mov     x2, #0
    mov     x3, #0
    mov     x8, #OPENAT_NR
    svc     #0
    cmp     x0, #0
    b.lt    fail
    mov     x19, x0

    mov     x0, x19
    adrp    x1, statbuf
    add     x1, x1, :lo12:statbuf
    mov     x8, #FSTAT_NR
    svc     #0
    cmp     x0, #0
    b.lt    fail_close

    /* key = (ino & 0xffff) | ((dev & 0xff) << 16) | (10 << 24). */
    adrp    x1, statbuf
    add     x1, x1, :lo12:statbuf
    ldr     x0, [x1, #0]
    and     x0, x0, #0xff
    lsl     x0, x0, #16
    ldr     x1, [x1, #8]
    and     x1, x1, #0xffff
    orr     x0, x0, x1
    mov     x1, #EPONOAM_PROJID
    lsl     x1, x1, #24
    orr     x20, x0, x1

    mov     x0, x19
    mov     x8, #CLOSE_NR
    svc     #0

    mov     x0, x20
    mov     x1, #0
    mov     x8, #MSGGET_NR
    svc     #0
    cmp     x0, #0
    b.lt    fail
    mov     x19, x0

    /* AArch64 long is 8 bytes; msgsnd excludes msgType from its length. */
    adrp    x1, message
    add     x1, x1, :lo12:message
    mov     x0, x19
    mov     x2, #136
    mov     x3, #0
    mov     x8, #MSGSND_NR
    svc     #0
    cmp     x0, #0
    b.lt    fail

    mov     x0, #0
    b       done

fail_close:
    mov     x0, x19
    mov     x8, #CLOSE_NR
    svc     #0
fail:
    mov     x0, #1

done:
    mov     x8, #EXIT_NR
    svc     #0

.section .rodata
queue_path:
    .asciz  "/tmp/epon_oam/epon_oam_cmd_queue"

.data
.align 3
message:
    .quad   1
    .word   EPONOAM_CMD_TYPE_UPDATACFG
    .word   1
    .space  128, 0

.bss
.align 3
statbuf:
    .space  128
