/* xpon-cputemp 进程入口：aarch64 Linux 入口 sp 指向 argc */
	.section .text._start,"ax"
	.globl _start
	.type _start, %function
_start:
	mov	x0, sp
	bl	xpon_main
	mov	x8, #93		/* __NR_exit */
	svc	#0
	.size _start, .-_start
