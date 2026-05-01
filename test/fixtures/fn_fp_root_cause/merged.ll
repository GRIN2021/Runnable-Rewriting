define void @root(i64 %pc) {
entrypoint:
  br label %bb.0x50000000

bb.0x50000000:
  ; 0x50000000: mov
  ; 0x50000002: lea
  ; 0x50000018: call
  ; 0x5000001b: jmp
  ; 0x50000021: mov
  ; 0x50000030: add
  ret void
}
