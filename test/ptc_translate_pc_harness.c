#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ptc.h"

static unsigned find_debug_insn_start(const PTCInterface *ptc) {
    unsigned index;

    for (index = 0; index < PTC_INSTRUCTION_NB_OPS; index++) {
        const char *name = ptc->opcode_defs[index].name;
        if (name != NULL && strcmp(name, "debug_insn_start") == 0) {
            return index;
        }
    }

    fprintf(stderr, "failed to find debug_insn_start opcode\n");
    exit(2);
}

int main(int argc, char **argv) {
    PTCInterface ptc = { 0 };
    uint64_t dynamic_va = 0;
    uint64_t entry = 0;
    uint64_t current_pc;
    size_t total_consumed = 0;
    unsigned debug_opcode;
    unsigned block;
    int single_shot = 0;

    if (argc == 3) {
        single_shot = strcmp(argv[2], "single-shot") == 0;
    }

    if (argc < 2 || argc > 3 || (argc == 3 && !single_shot)) {
        fprintf(stderr, "usage: %s <elf-binary> [single-shot]\n", argv[0]);
        return 2;
    }

    if (ptc_load(NULL, &ptc, argv[1], "") != 0) {
        fprintf(stderr, "ptc_load failed for %s\n", argv[1]);
        return 2;
    }

    memcpy(&entry, ptc.initialized_env + ptc.pc, sizeof(entry));
    debug_opcode = find_debug_insn_start(&ptc);
    current_pc = entry;

    if (single_shot) {
        PTCInstructionList instructions = { 0 };
        size_t consumed;
        unsigned index;

        ptc_instruction_list_malloc(&instructions);
        consumed = ptc.translate(current_pc, 1, &instructions, &dynamic_va);
        total_consumed += consumed;

        for (index = 0; index < instructions.instruction_count; index++) {
            PTCInstruction *instruction = &instructions.instructions[index];
            if (instruction->opc != debug_opcode) {
                continue;
            }
            printf("pc=0x%016" PRIx64 "\n", instruction->args[0]);
        }

        ptc_instruction_list_free(&instructions);
        printf("consumed=%zu\n", total_consumed);
        return 0;
    }

    for (block = 0; block < 64; block++) {
        PTCInstructionList instructions = { 0 };
        size_t consumed;
        unsigned index;

        ptc_instruction_list_malloc(&instructions);
        consumed = ptc.translate(current_pc, 1, &instructions, &dynamic_va);
        total_consumed += consumed;

        for (index = 0; index < instructions.instruction_count; index++) {
            PTCInstruction *instruction = &instructions.instructions[index];
            if (instruction->opc != debug_opcode) {
                continue;
            }
            printf("pc=0x%016" PRIx64 "\n", instruction->args[0]);
        }

        ptc_instruction_list_free(&instructions);

        if (consumed == 0) {
            break;
        }

        current_pc += consumed;
        if (current_pc >= entry + 64) {
            break;
        }
    }

    printf("consumed=%zu\n", total_consumed);
    return 0;
}
