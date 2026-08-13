"""Launch mlx_lm.server with distributed backend forced to 'ring' so it never
probes for MPI. Needed on this box because conda ships MPICH at
/opt/homebrew/anaconda3/lib/libmpi.dylib, which MLX's auto-probe rejects with
'MPI found but it does not appear to be Open MPI' and the server fails to
start. We don't need distributed inference — we want a single-process server.
"""
from __future__ import annotations

import sys

import mlx.core as mx

_orig_init = mx.distributed.init


def _ring_only(strict: bool = False, backend: str = "any"):
    return _orig_init(strict=strict, backend="ring")


mx.distributed.init = _ring_only

from mlx_lm.server import main as server_main

if __name__ == "__main__":
    sys.exit(server_main())
