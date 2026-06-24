.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vmovdqu ymm0, ymmword ptr [rip + scratch]
    vpxor ymm1, ymm0, ymm0
    vpshufb ymm2, ymm1, ymm0
    vperm2i128 ymm3, ymm2, ymm0, 0x31
    vmovdqu ymmword ptr [rip + scratch], ymm3
    vzeroupper
    mov eax, 60
    xor edi, edi
    syscall

.section .data
.align 32
scratch:
    .zero 32
