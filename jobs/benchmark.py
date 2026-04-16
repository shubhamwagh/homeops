import time
import numpy as np

print(f"NumPy version: {np.__version__}")
print(f"Running matrix multiply benchmark...\n")

sizes = [512, 1024, 2048]

for n in sizes:
    A = np.random.rand(n, n).astype(np.float32)
    B = np.random.rand(n, n).astype(np.float32)

    start = time.perf_counter()
    C = A @ B
    elapsed = time.perf_counter() - start

    gflops = (2 * n ** 3) / elapsed / 1e9
    print(f"  {n}x{n}  →  {elapsed:.3f}s  ({gflops:.1f} GFLOPS)")

print("\nDone.")
