.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vmovdqa64 zmm1, zmm0
    mov eax, 60
    xor edi, edi
    syscall
