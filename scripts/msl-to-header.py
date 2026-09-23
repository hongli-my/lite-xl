#!/usr/bin/env python3
"""Convert MSL shader source into a C string literal header.

Usage:
  msl-to-header.py                     # default: src/gpu_shaders.msl -> src/gpu_shaders_msl.h
  msl-to-header.py <input.msl> <output.h>  # explicit paths (used by meson custom_target)
"""
import sys, pathlib

if len(sys.argv) == 3:
    msl_path = pathlib.Path(sys.argv[1])
    out_path = pathlib.Path(sys.argv[2])
else:
    ROOT = pathlib.Path(__file__).resolve().parent.parent
    msl_path = ROOT / "src" / "gpu_shaders.msl"
    out_path = ROOT / "src" / "gpu_shaders_msl.h"

msl = msl_path.read_text()
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
out_path.write_text(''.join(out))
print(f"Generated {out_path} ({len(''.join(out))} bytes)")
