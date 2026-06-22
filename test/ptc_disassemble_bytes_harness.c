#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ptc.h"

static int hex_value(char c) {
    if (c >= '0' && c <= '9') {
        return c - '0';
    }
    if (c >= 'a' && c <= 'f') {
        return 10 + (c - 'a');
    }
    if (c >= 'A' && c <= 'F') {
        return 10 + (c - 'A');
    }
    return -1;
}

static uint8_t *parse_bytes(const char *text, size_t *out_size) {
    size_t capacity = strlen(text) / 2 + 1;
    uint8_t *buffer = malloc(capacity);
    int high = -1;
    size_t size = 0;

    if (buffer == NULL) {
        return NULL;
    }

    for (const char *cursor = text; *cursor != '\0'; cursor++) {
        int value = hex_value(*cursor);
        if (value < 0) {
            continue;
        }
        if (high < 0) {
            high = value;
            continue;
        }
        buffer[size++] = (uint8_t) ((high << 4) | value);
        high = -1;
    }

    if (high >= 0) {
        free(buffer);
        return NULL;
    }

    *out_size = size;
    return buffer;
}

int main(int argc, char **argv) {
    char *rendered = NULL;
    size_t rendered_size = 0;
    size_t byte_count = 0;
    int flags = 2;
    int count;
    uint8_t *bytes;
    FILE *stream;

    if (argc < 2 || argc > 3) {
        fprintf(stderr, "usage: %s <hex-bytes> [flags]\n", argv[0]);
        return 2;
    }

    bytes = parse_bytes(argv[1], &byte_count);
    if (bytes == NULL || byte_count == 0) {
        fprintf(stderr, "failed to parse byte string: %s\n", argv[1]);
        free(bytes);
        return 2;
    }

    if (argc == 3) {
        flags = (int) strtol(argv[2], NULL, 0);
    }

    stream = open_memstream(&rendered, &rendered_size);
    if (stream == NULL) {
        perror("open_memstream");
        free(bytes);
        return 2;
    }

    count = ptc_disassemble_bytes(stream, bytes, byte_count, flags);
    fflush(stream);
    fclose(stream);

    printf("count=%d\n", count);
    if (rendered != NULL) {
        fputs(rendered, stdout);
    }

    free(rendered);
    free(bytes);
    return count < 0 ? 1 : 0;
}
