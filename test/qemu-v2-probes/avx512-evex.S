.intel_syntax noprefix

.section .text
.global _start
.type _start, @function
_start:
    vpxorq zmm0, zmm0, zmm0
    vmovdqa64 zmm1, zmm0
    vmovdqu64 zmmword ptr [rip + scratch], zmm1
    vmovdqu64 zmm2, zmmword ptr [rip + scratch]
    vpshufb zmm3, zmm2, zmm2
    vpaddd zmm4, zmm3, zmm2
    vpternlogq zmm5, zmm4, zmm3, 0x96
    vpclmullqlqdq zmm6, zmm5, zmm4
    vpclmullqhqdq zmm7, zmm5, zmm4
    vpclmulhqlqdq zmm8, zmm5, zmm4
    vpclmulhqhqdq zmm9, zmm5, zmm4
    vaesenc zmm10, zmm9, zmm8
    vaesenclast zmm11, zmm10, zmm7
    vbroadcastf64x2 zmm12, xmmword ptr [rip + scratch]
    vpslldq zmm13, zmm12, 4
    vpsrldq zmm14, zmm13, 4
    vextracti32x4 xmm15, zmm14, 1
    vextracti64x4 ymm16, zmm14, 1
    vmovdqu8 zmmword ptr [rip + scratch], zmm14
    vzeroupper
    mov eax, 60
    xor edi, edi
    syscall

.section .data
.align 64
scratch:
    .zero 64
