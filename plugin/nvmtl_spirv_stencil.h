/*
 * NullMoth NVIDIA driver for macOS
 * Copyright (c) 2026 NullMoth Systems.
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#include <stddef.h>
#include <stdint.h>

#define NVMTL_STENCIL_EMU_OFFSET 160u  /* native::stencil_export::STENCIL_EXPORT_PUSH_OFFSET */

/* Look for the translator's stencil export field on an actual PushConstant block. Uniform and
 * storage buffers can have ordinary members at the same offset. Their draws must not be replayed. */
static inline uint32_t nvmtl_spirv_stencil_push_block(const uint32_t *words, size_t count, uint32_t pointer)
{
    uint32_t block = 0;
    for (size_t i = 5; i < count; ) {
        uint32_t size = words[i] >> 16, op = words[i] & 0xffffu;
        if (!size || size > count - i) return 0;
        if (op == 32 && size == 4 && words[i + 1] == pointer && words[i + 2] == 9) {
            block = words[i + 3];  /* OpTypePointer PushConstant */
            break;
        }
        i += size;
    }
    if (!block) return 0;

    for (size_t i = 5; i < count; ) {
        uint32_t size = words[i] >> 16, op = words[i] & 0xffffu;
        if (!size || size > count - i) return 0;
        if (op == 72 && size == 5 && words[i + 1] == block && words[i + 2] == 0 &&
            words[i + 3] == 35 && words[i + 4] == NVMTL_STENCIL_EMU_OFFSET)
            return 1;  /* OpMemberDecorate: first member at the stencil bit's offset */
        i += size;
    }
    return 0;
}

static inline uint32_t nvmtl_spirv_has_stencil_push(const void *code, size_t bytes)
{
    const uint32_t *words = (const uint32_t *)code;
    const size_t count = bytes / sizeof(*words);
    if (!words || bytes % sizeof(*words) || count < 5 || words[0] != 0x07230203u) return 0;
    for (size_t i = 5; i < count; ) {
        uint32_t size = words[i] >> 16, op = words[i] & 0xffffu;
        if (!size || size > count - i) return 0;
        if (op == 59 && size >= 4 && words[i + 3] == 9 &&
            nvmtl_spirv_stencil_push_block(words, count, words[i + 1]))  /* OpVariable PushConstant */
            return 1;
        i += size;
    }
    return 0;
}
