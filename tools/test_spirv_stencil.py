#!/usr/bin/env python3
"""Stencil export detection must distinguish push constants from ordinary shader buffers."""

from pathlib import Path
import subprocess
import tempfile


PLUGIN = Path(__file__).resolve().parents[1] / "plugin"
SOURCE = r"""
#include <assert.h>
#include "nvmtl_spirv_stencil.h"

#define HEADER 0x07230203u, 0x00010300u, 0, 12, 0
#define OFFSET(block, member, offset) (5u << 16) | 72u, block, member, 35, offset
#define PTR(type, storage, block) (4u << 16) | 32u, type, storage, block
#define VAR(type, var, storage) (4u << 16) | 59u, type, var, storage

int main(void) {
    const uint32_t ordinary_uniform[] = {
        HEADER, OFFSET(1, 6, 160), PTR(2, 2, 1), VAR(2, 3, 2)
    };
    const uint32_t unrelated_push[] = {
        HEADER, OFFSET(1, 0, 160), OFFSET(4, 0, 80),
        PTR(2, 12, 1), PTR(5, 9, 4), VAR(2, 3, 12), VAR(5, 6, 9)
    };
    const uint32_t stencil_push[] = {
        HEADER, OFFSET(1, 6, 160), OFFSET(4, 0, 160),
        PTR(2, 2, 1), PTR(5, 9, 4), VAR(2, 3, 2), VAR(5, 6, 9)
    };
    const uint32_t pointer_without_variable[] = {
        HEADER, OFFSET(1, 0, 160), PTR(2, 9, 1)
    };
    assert(!nvmtl_spirv_has_stencil_push(ordinary_uniform, sizeof(ordinary_uniform)));
    assert(!nvmtl_spirv_has_stencil_push(unrelated_push, sizeof(unrelated_push)));
    assert(nvmtl_spirv_has_stencil_push(stencil_push, sizeof(stencil_push)));
    assert(!nvmtl_spirv_has_stencil_push(pointer_without_variable, sizeof(pointer_without_variable)));
    assert(!nvmtl_spirv_has_stencil_push(stencil_push, sizeof(stencil_push) - 4));
    assert(!nvmtl_spirv_has_stencil_push(stencil_push, sizeof(stencil_push) - 1));
}
"""

with tempfile.TemporaryDirectory() as directory:
    binary = Path(directory) / "stencil-test"
    subprocess.run(
        ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-I", str(PLUGIN),
         "-x", "c", "-o", str(binary), "-"],
        input=SOURCE, text=True, check=True,
    )
    subprocess.run([binary], check=True)

print("ok: only a PushConstant variable with the stencil offset enables draw replay")
