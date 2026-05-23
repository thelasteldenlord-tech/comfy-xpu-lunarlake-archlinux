#!/usr/bin/env bash
# =============================================================================
# comfyui_xpu_probe.sh
# Intel Arc / XPU environment diagnostic for ComfyUI (Lunar Lake / shared RAM)
# Outputs a timestamped report to $HOME/.reports/
# Usage: bash comfyui_xpu_probe.sh [--comfyui-dir /path/to/ComfyUI]
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
COMFYUI_DIR="${COMFYUI_DIR:-$HOME/ComfyUI}"
REPORT_DIR="$HOME/.reports"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
REPORT_FILE="$REPORT_DIR/xpu_probe_${TIMESTAMP}.txt"
VENV_DIR="$COMFYUI_DIR/.venv"
PYTHON=""

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --comfyui-dir) COMFYUI_DIR="$2"; VENV_DIR="$COMFYUI_DIR/.venv"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
HR="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
section() { echo -e "\n$HR\n  $1\n$HR"; }
kv()      { printf "  %-36s %s\n" "$1:" "$2"; }
warn()    { echo "  [WARN] $1"; }
ok()      { echo "  [ OK ] $1"; }
fail()    { echo "  [FAIL] $1"; }

cmd_or_na() {
    local out
    out=$(eval "$1" 2>/dev/null) && echo "$out" || echo "N/A"
}

# ---------------------------------------------------------------------------
# Resolve Python
# ---------------------------------------------------------------------------
resolve_python() {
    if [[ -x "$VENV_DIR/bin/python" ]]; then
        PYTHON="$VENV_DIR/bin/python"
    elif command -v uv &>/dev/null && [[ -d "$COMFYUI_DIR" ]]; then
        # Try uv run from within the project dir
        PYTHON="uv run --project $COMFYUI_DIR python"
    elif command -v python3 &>/dev/null; then
        PYTHON="python3"
        warn "Falling back to system python3 — results may not reflect ComfyUI venv"
    else
        echo "ERROR: No Python found. Set COMFYUI_DIR or activate your venv first."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Run a Python snippet and return stdout (stderr silenced unless empty)
# ---------------------------------------------------------------------------
pyrun() {
    local code="$1"
    eval "$PYTHON" - <<EOF 2>/dev/null
$code
EOF
}

pyrun_raw() {
    local code="$1"
    eval "$PYTHON" - <<EOF
$code
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
mkdir -p "$REPORT_DIR"

{
# ── Header ─────────────────────────────────────────────────────────────────
echo "$HR"
echo "  ComfyUI / Intel Arc XPU Environment Probe"
echo "  Generated : $(date '+%A %Y-%m-%d %H:%M:%S %Z')"
echo "  Host      : $(hostname)"
echo "  Report    : $REPORT_FILE"
echo "$HR"

# ── 1. System overview ─────────────────────────────────────────────────────
section "1. SYSTEM OVERVIEW"

kv "Kernel" "$(uname -r)"
kv "OS" "$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || uname -s)"
kv "Architecture" "$(uname -m)"
kv "CPU model" "$(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
kv "CPU cores (logical)" "$(nproc)"
kv "CPU cores (physical)" "$(grep '^core id' /proc/cpuinfo | sort -u | wc -l)"

# Memory
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
AVAIL_RAM_KB=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$(awk "BEGIN {printf \"%.1f\", $TOTAL_RAM_KB/1048576}")
AVAIL_RAM_GB=$(awk "BEGIN {printf \"%.1f\", $AVAIL_RAM_KB/1048576}")
kv "Total RAM" "${TOTAL_RAM_GB} GB"
kv "Available RAM" "${AVAIL_RAM_GB} GB"
kv "Swap total" "$(grep SwapTotal /proc/meminfo | awk '{printf "%.1f GB", $2/1048576}')"

# Distrobox / container detection
if [[ -f /run/.containerenv ]]; then
    CONTAINER_NAME=$(grep name /run/.containerenv 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "unknown")
    kv "Container" "distrobox / podman ($CONTAINER_NAME)"
elif [[ -f /.dockerenv ]]; then
    kv "Container" "docker"
else
    kv "Container" "none (bare metal / VM)"
fi

# ── 2. Intel GPU / driver info ─────────────────────────────────────────────
section "2. INTEL GPU & DRIVER"

if command -v intel_gpu_top &>/dev/null; then
    kv "intel_gpu_top" "available"
else
    kv "intel_gpu_top" "not found (install intel-gpu-tools for runtime monitoring)"
fi

# DRM devices
echo ""
echo "  DRM render nodes:"
for dev in /dev/dri/render*; do
    echo "    $dev"
done

# lspci for Intel GPU
echo ""
echo "  PCI GPU devices:"
if command -v lspci &>/dev/null; then
    lspci | grep -iE 'vga|display|3d|2d' | sed 's/^/    /'
else
    warn "lspci not available"
fi

# Kernel driver in use
echo ""
echo "  Kernel modules (i915 / xe):"
for mod in i915 xe; do
    if lsmod 2>/dev/null | grep -q "^$mod "; then
        ok "$mod loaded"
    else
        echo "  [ -- ] $mod not loaded"
    fi
done

# Driver version via modinfo
for mod in xe i915; do
    if modinfo "$mod" &>/dev/null; then
        VER=$(modinfo "$mod" 2>/dev/null | grep '^version' | awk '{print $2}' || echo "N/A")
        kv "  $mod version" "$VER"
        break
    fi
done

# ── 3. Python & venv ───────────────────────────────────────────────────────
section "3. PYTHON ENVIRONMENT"

resolve_python
kv "Python binary" "$PYTHON"
kv "Python version" "$(pyrun 'import sys; print(sys.version.split()[0])')"
kv "Python prefix" "$(pyrun 'import sys; print(sys.prefix)')"

# uv
if command -v uv &>/dev/null; then
    kv "uv version" "$(uv --version 2>/dev/null)"
else
    kv "uv" "not found"
fi

kv "ComfyUI dir" "$COMFYUI_DIR"
if [[ -d "$COMFYUI_DIR" ]]; then
    ok "ComfyUI directory found"
    # Git rev if available
    if [[ -d "$COMFYUI_DIR/.git" ]]; then
        GIT_HASH=$(git -C "$COMFYUI_DIR" rev-parse --short HEAD 2>/dev/null || echo "N/A")
        GIT_DATE=$(git -C "$COMFYUI_DIR" log -1 --format="%ci" 2>/dev/null || echo "N/A")
        kv "ComfyUI git hash" "$GIT_HASH"
        kv "ComfyUI last commit" "$GIT_DATE"
    fi
else
    fail "ComfyUI directory not found at $COMFYUI_DIR"
fi

# ── 4. PyTorch & XPU detection ─────────────────────────────────────────────
section "4. PYTORCH & XPU DETECTION"

pyrun_raw '
import sys

def kv(k, v):
    print(f"  {k:<36} {v}")

try:
    import torch
    kv("PyTorch version", torch.__version__)
    kv("Build CUDA available", str(torch.cuda.is_available()))

    # XPU
    xpu_ok = hasattr(torch, "xpu") and torch.xpu.is_available()
    kv("XPU available", str(xpu_ok))

    if xpu_ok:
        dev_count = torch.xpu.device_count()
        kv("XPU device count", str(dev_count))
        for i in range(dev_count):
            props = torch.xpu.get_device_properties(i)
            kv(f"  XPU[{i}] name", props.name)
            total_mb = props.total_memory // (1024**2)
            kv(f"  XPU[{i}] total memory", f"{total_mb} MB  ({total_mb/1024:.1f} GB)")
            if hasattr(props, "driver_version"):
                kv(f"  XPU[{i}] driver version", str(props.driver_version))
            if hasattr(props, "max_compute_units"):
                kv(f"  XPU[{i}] compute units", str(props.max_compute_units))

        # Current memory state
        mem_alloc = torch.xpu.memory_allocated(0) // (1024**2)
        mem_reserved = torch.xpu.memory_reserved(0) // (1024**2)
        kv("  XPU[0] allocated now", f"{mem_alloc} MB")
        kv("  XPU[0] reserved now", f"{mem_reserved} MB")
    else:
        print("  [WARN] XPU not available — check PyTorch XPU wheel and driver")

    # BF16 support check
    if xpu_ok:
        try:
            t = torch.zeros(1, dtype=torch.bfloat16, device="xpu")
            kv("BF16 on XPU", "supported")
        except Exception as e:
            kv("BF16 on XPU", f"FAILED: {e}")

        # FP16
        try:
            t = torch.zeros(1, dtype=torch.float16, device="xpu")
            kv("FP16 on XPU", "supported")
        except Exception as e:
            kv("FP16 on XPU", f"FAILED: {e}")

        # FP8 probe
        try:
            t = torch.zeros(1, dtype=torch.float8_e4m3fn, device="xpu")
            kv("FP8 e4m3fn on XPU", "supported")
        except Exception as e:
            kv("FP8 e4m3fn on XPU", f"not supported: {e}")

    # SDPA / attention backends
    try:
        import torch.nn.functional as F
        kv("SDPA (scaled_dot_product_attention)", "available" if hasattr(F, "scaled_dot_product_attention") else "not found")
    except:
        kv("SDPA", "N/A")

except ImportError as e:
    print(f"  [FAIL] Could not import torch: {e}")
    sys.exit(1)
'

# ── 5. Relevant installed packages ─────────────────────────────────────────
section "5. KEY INSTALLED PACKAGES"

pyrun_raw '
import importlib.metadata as meta
import sys

packages = [
    "torch", "torchvision", "torchaudio",
    "intel-extension-for-pytorch",
    "triton",
    "xformers",
    "diffusers",
    "transformers",
    "accelerate",
    "safetensors",
    "einops",
    "scipy",
    "numpy",
    "pillow",
    "aiohttp",
    "comfyui",
]

for pkg in packages:
    try:
        ver = meta.version(pkg)
        print(f"  {pkg:<40} {ver}")
    except meta.PackageNotFoundError:
        print(f"  {pkg:<40} not installed")
'

# ── 6. XPU micro-benchmark ─────────────────────────────────────────────────
section "6. XPU MICRO-BENCHMARK (matrix multiply)"

pyrun_raw '
import sys

try:
    import torch, time

    if not (hasattr(torch, "xpu") and torch.xpu.is_available()):
        print("  [SKIP] XPU not available")
        sys.exit(0)

    def bench(dtype, label, size=4096):
        try:
            a = torch.randn(size, size, dtype=dtype, device="xpu")
            b = torch.randn(size, size, dtype=dtype, device="xpu")
            torch.xpu.synchronize()
            t0 = time.perf_counter()
            for _ in range(5):
                c = torch.mm(a, b)
            torch.xpu.synchronize()
            elapsed = (time.perf_counter() - t0) / 5
            flops = 2 * size**3
            tflops = flops / elapsed / 1e12
            print(f"  {label:<20} size={size}x{size}  avg={elapsed*1000:.1f}ms  {tflops:.2f} TFLOPS")
        except Exception as e:
            print(f"  {label:<20} FAILED: {e}")

    bench(torch.float32, "FP32 matmul")
    bench(torch.bfloat16, "BF16 matmul")
    bench(torch.float16,  "FP16 matmul")

    # Memory bandwidth proxy: large tensor copy
    print("")
    for dtype, label in [(torch.bfloat16, "BF16 memcopy"), (torch.float32, "FP32 memcopy")]:
        try:
            sz = 512 * 1024 * 1024 // torch.finfo(dtype).bits * 8  # ~512MB
            src = torch.ones(sz, dtype=dtype, device="xpu")
            torch.xpu.synchronize()
            t0 = time.perf_counter()
            dst = src.clone()
            torch.xpu.synchronize()
            elapsed = time.perf_counter() - t0
            bw_gb = (src.nbytes * 2) / elapsed / 1e9
            print(f"  {label:<20} ~{src.nbytes/1e9:.2f} GB  {elapsed*1000:.1f}ms  {bw_gb:.1f} GB/s")
        except Exception as e:
            print(f"  {label:<20} FAILED: {e}")

except ImportError as e:
    print(f"  [FAIL] {e}")
'

# ── 7. ComfyUI flag recommendations ────────────────────────────────────────
section "7. RECOMMENDED COMFYUI LAUNCH FLAGS (auto-tuned)"

pyrun_raw '
import sys

try:
    import torch

    xpu_ok = hasattr(torch, "xpu") and torch.xpu.is_available()

    flags = []
    notes = []

    if xpu_ok:
        # BF16 support?
        try:
            torch.zeros(1, dtype=torch.bfloat16, device="xpu")
            flags += ["--bf16-unet", "--bf16-vae"]
            notes.append("BF16 confirmed on XPU — halves model memory vs FP32")
        except:
            flags += ["--fp16-unet"]
            notes.append("BF16 failed, falling back to --fp16-unet")

        # FP8 probe
        try:
            torch.zeros(1, dtype=torch.float8_e4m3fn, device="xpu")
            notes.append("FP8 e4m3fn appears supported — consider --fp8_e4m3fn-unet for speed (test for artifacts)")
        except:
            notes.append("FP8 not supported on this build — skip fp8 flags")

        flags.append("--use-pytorch-cross-attention")
        notes.append("SDPA attention: correct backend for XPU (xformers is CUDA-only)")

        flags.append("--async-offload")
        notes.append("async-offload now has XPU support — overlaps memory transfer with compute")

        # Memory sizing
        import subprocess, re
        props = torch.xpu.get_device_properties(0)
        total_gb = props.total_memory / (1024**3)

        if total_gb >= 20:
            flags.append("--highvram")
            notes.append(f"Shared pool is {total_gb:.0f}GB — highvram keeps models resident between runs")
            flags.append("--reserve-vram 2")
            notes.append("Reserve 2GB for OS/display compositor on shared-RAM iGPU")
        elif total_gb >= 12:
            flags.append("--normalvram")
            notes.append(f"Moderate shared pool ({total_gb:.0f}GB) — normalvram is safe default")
            flags.append("--reserve-vram 1")

        flags.append("--fast")
        notes.append("--fast enables perf feature suite; safe for workflow testing, optional for finals")

    else:
        flags.append("--cpu")
        notes.append("XPU not detected — falling back to CPU (slow!)")

    print("\n  Launch command:")
    print(f"\n    python main.py " + " \\\\\n      ".join(flags))
    print("\n  Rationale:")
    for i, n in enumerate(notes, 1):
        print(f"    {i:2}. {n}")

except ImportError as e:
    print(f"  [FAIL] {e}")
'

# ── 8. Environment variables relevant to XPU ───────────────────────────────
section "8. RELEVANT ENVIRONMENT VARIABLES"

for var in \
    ONEAPI_DEVICE_SELECTOR \
    ZE_AFFINITY_MASK \
    SYCL_DEVICE_FILTER \
    LIBVA_DRIVER_NAME \
    LIBVA_DRIVERS_PATH \
    INTEL_MEDIA_RUNTIME \
    LD_LIBRARY_PATH \
    PYTHONPATH \
    VIRTUAL_ENV \
    UV_PROJECT_ENVIRONMENT \
    NEOReadDebugKeys \
    OverrideGpuAddressSpace; do
    val="${!var:-<not set>}"
    printf "  %-36s %s\n" "$var" "$val"
done

# ── 9. Potential issues checklist ──────────────────────────────────────────
section "9. CHECKLIST & POTENTIAL ISSUES"

# Check render node permissions
echo "  Render node access:"
for dev in /dev/dri/render*; do
    if [[ -r "$dev" ]]; then
        ok "$dev readable"
    else
        fail "$dev not readable — add user to 'render' group: sudo usermod -aG render \$USER"
    fi
done

# video group
echo ""
echo "  Group membership:"
for grp in render video; do
    if id -nG 2>/dev/null | tr ' ' '\n' | grep -q "^$grp$"; then
        ok "user is in '$grp' group"
    else
        warn "user NOT in '$grp' group — may need: sudo usermod -aG $grp \$USER"
    fi
done

# Level Zero / oneAPI runtime
echo ""
echo "  Level Zero / oneAPI runtime:"
if ldconfig -p 2>/dev/null | grep -q "libze_intel_gpu"; then
    ok "libze_intel_gpu found in ldconfig cache"
elif find /usr /opt 2>/dev/null | grep -q "libze_intel_gpu"; then
    warn "libze_intel_gpu found on disk but may not be in ldconfig cache (run sudo ldconfig)"
else
    warn "libze_intel_gpu not found — Level Zero GPU runtime may not be installed"
    echo "         Install: intel-level-zero-gpu / intel-opencl-icd"
fi

# libva
if ldconfig -p 2>/dev/null | grep -q "libva.so"; then
    ok "libva (VA-API) found"
else
    warn "libva not found — not critical for XPU compute but useful for display"
fi

# ── 10. Footer ─────────────────────────────────────────────────────────────
echo ""
echo "$HR"
echo "  Report complete. To monitor GPU during a generation run:"
echo "    watch -n 0.5 intel_gpu_top"
echo "  Or for memory detail:"
echo "    watch -n 1 'cat /sys/class/drm/card*/clients/*/name 2>/dev/null | head -20'"
echo ""
echo "  Report saved to: $REPORT_FILE"
echo "$HR"

} 2>&1 | tee "$REPORT_FILE"

echo ""
echo "Done. Full report: $REPORT_FILE"
