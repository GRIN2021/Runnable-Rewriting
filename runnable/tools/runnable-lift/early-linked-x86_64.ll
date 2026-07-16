; ModuleID = '/home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting/runnable/runtime/early-linked.c'
source_filename = "/home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting/runnable/runtime/early-linked.c"
target datalayout = "e-m:e-i64:64-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.__jmp_buf_tag = type { [8 x i64], i32, %struct.__sigset_t }
%struct.__sigset_t = type { [16 x i64] }

@saved_registers = external dso_local global i64*, align 8
@jmp_buffer = external dso_local global [1 x %struct.__jmp_buf_tag], align 16

; Function Attrs: noinline nounwind optnone uwtable
define dso_local i64 @ignore() #0 !dbg !11 {
  ret i64 add nsw (i64 add nsw (i64 add nsw (i64 ptrtoint (i64** @saved_registers to i64), i64 ptrtoint (i32 (%struct.__jmp_buf_tag*)* @setjmp to i64)), i64 ptrtoint ([1 x %struct.__jmp_buf_tag]* @jmp_buffer to i64)), i64 ptrtoint (i1 (i64)* @is_executable to i64)), !dbg !13
}

; Function Attrs: nounwind returns_twice
declare dso_local i32 @setjmp(%struct.__jmp_buf_tag*) #1

declare dso_local zeroext i1 @is_executable(i64) #2

attributes #0 = { noinline nounwind optnone uwtable "correctly-rounded-divide-sqrt-fp-math"="false" "disable-tail-calls"="false" "less-precise-fpmad"="false" "no-frame-pointer-elim"="true" "no-frame-pointer-elim-non-leaf" "no-infs-fp-math"="false" "no-jump-tables"="false" "no-nans-fp-math"="false" "no-signed-zeros-fp-math"="false" "no-trapping-math"="false" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+fxsr,+mmx,+sse,+sse2,+x87" "unsafe-fp-math"="false" "use-soft-float"="false" }
attributes #1 = { nounwind returns_twice "correctly-rounded-divide-sqrt-fp-math"="false" "disable-tail-calls"="false" "less-precise-fpmad"="false" "no-frame-pointer-elim"="true" "no-frame-pointer-elim-non-leaf" "no-infs-fp-math"="false" "no-nans-fp-math"="false" "no-signed-zeros-fp-math"="false" "no-trapping-math"="false" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+fxsr,+mmx,+sse,+sse2,+x87" "unsafe-fp-math"="false" "use-soft-float"="false" }
attributes #2 = { "correctly-rounded-divide-sqrt-fp-math"="false" "disable-tail-calls"="false" "less-precise-fpmad"="false" "no-frame-pointer-elim"="true" "no-frame-pointer-elim-non-leaf" "no-infs-fp-math"="false" "no-nans-fp-math"="false" "no-signed-zeros-fp-math"="false" "no-trapping-math"="false" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+fxsr,+mmx,+sse,+sse2,+x87" "unsafe-fp-math"="false" "use-soft-float"="false" }

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!7, !8, !9}
!llvm.ident = !{!10}

!0 = distinct !DICompileUnit(language: DW_LANG_C99, file: !1, producer: "clang version 7.0.0 ", isOptimized: false, runtimeVersion: 0, emissionKind: FullDebug, enums: !2, retainedTypes: !3)
!1 = !DIFile(filename: "/home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting/runnable/runtime/early-linked.c", directory: "/home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting/build-codex-dynamic-current")
!2 = !{}
!3 = !{!4}
!4 = !DIDerivedType(tag: DW_TAG_typedef, name: "intptr_t", file: !5, line: 76, baseType: !6)
!5 = !DIFile(filename: "/usr/include/stdint.h", directory: "/home/iskindar/Project/runnable-rewriting-project/Runnable-Rewriting/build-codex-dynamic-current")
!6 = !DIBasicType(name: "long int", size: 64, encoding: DW_ATE_signed)
!7 = !{i32 2, !"Dwarf Version", i32 4}
!8 = !{i32 2, !"Debug Info Version", i32 3}
!9 = !{i32 1, !"wchar_size", i32 4}
!10 = !{!"clang version 7.0.0 "}
!11 = distinct !DISubprogram(name: "ignore", scope: !1, file: !1, line: 13, type: !12, isLocal: false, isDefinition: true, scopeLine: 13, flags: DIFlagPrototyped, isOptimized: false, unit: !0, retainedNodes: !2)
!12 = !DISubroutineType(types: !3)
!13 = !DILocation(line: 14, column: 3, scope: !11)
