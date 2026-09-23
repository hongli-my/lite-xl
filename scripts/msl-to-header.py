#!/usr/bin/env python3
"""Convert src/gpu_shaders.msl into src/gpu_shaders_msl.h (C string literal)."""
import sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
msl = (ROOT / "src" / "gpu_shaders.msl").read_text()
out = []
out.append('/* Auto-generated from src/gpu_shaders.msl. Do not edit by hand."\n')
out.append('   * Embedded as a C string literal for SDL_CreateGPUShader (MSL source). */\n')
out.append('#ifndef GPU_SHADERS_MSL_H\n')
out.append('#define GPU_SHADERS_MSL_H\n')
out.append('\n')
out.append('static const char gpu_shaders_msl[] =\n')
for line in msl.splitlines(keepends=True):
    out.append('  "')
    out.append(line.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n"\n').replace('\t', '\\t'))
    if not line.endswith('\n'):
        out.append('"\n')
out.append('  ;\n')
out.append('\n')
out.append('#endif /* GPU_SHADERS_MSL_H */\n')
(ROOT / "src" / "gpu_shaders_msl.h").write_text(''.join(out))
print(f"Generated src/gpu_shaders_msl.h ({len(''.join(out))} bytes)")
