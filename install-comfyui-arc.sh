#!/usr/bin/env bash
###############################################################################
# ComfyUI Installation — Intel Arc / Lunar Lake (Xe2) on CachyOS
#
# Python + venv managed by uv.
# PyTorch installed from the XPU wheel index (NOT a CUDA build).
#   → torch.cuda.is_available() will return False  ← EXPECTED, not a bug
#   → torch.xpu.is_available()  will return True   ← this is your GPU
###############################################################################
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_step() { echo -e "\n${BOLD}${BLUE}━━━ $* ${NC}"; }
die()      { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

PYTHON_VERSION="3.12"
COMFYUI_DIR="${HOME}/ComfyUI"
AUR_HELPER=""

# Run uv pip inside the project venv without needing 'source activate'
venv_pip()    { VIRTUAL_ENV="${COMFYUI_DIR}/.venv" uv pip "$@"; }
venv_python() { "${COMFYUI_DIR}/.venv/bin/python" "$@"; }

###############################################################################
# 1. Pre-flight checks
###############################################################################
step_preflight() {
    log_step "Pre-flight checks"

    grep -qi "cachyos\|arch linux" /etc/os-release 2>/dev/null && \
        log_ok "OS: CachyOS / Arch Linux" || \
        log_warn "OS not Arch/CachyOS — script may still work"

    # Required binaries
    for cmd in git uv pacman; do
        command -v "$cmd" &>/dev/null || die "Required command not found: $cmd"
    done
    log_ok "git  — $(git --version)"
    log_ok "uv   — $(uv --version)"
    log_ok "pacman present"

    # AUR helper
    if   command -v paru &>/dev/null; then AUR_HELPER="paru"; log_ok "AUR helper: paru"
    elif command -v yay  &>/dev/null; then AUR_HELPER="yay";  log_ok "AUR helper: yay"
    else log_warn "No AUR helper (paru/yay) — AUR packages will be skipped"
    fi

    # GPU hardware
    if lspci 2>/dev/null | grep -qi "arc\|xe.*graphics\|lunar lake"; then
        local gpu_line
        gpu_line=$(lspci 2>/dev/null | grep -i "vga compatible" | head -1 | sed 's/.*: //')
        log_ok "GPU: ${gpu_line:-Intel Arc detected}"
    else
        log_warn "Intel Arc GPU not visible in lspci — check that drivers are loaded"
    fi

    # DRI render node
    if [[ -e /dev/dri/renderD128 ]]; then
        log_ok "/dev/dri/renderD128 present"
    else
        log_warn "/dev/dri/renderD128 missing — GPU acceleration may not be accessible"
    fi

    # sudo
    sudo -v || die "sudo access is required"
}

###############################################################################
# 2. System packages
###############################################################################
step_system_packages() {
    log_step "System packages (pacman)"

    # Minimal set needed for Level Zero / OpenCL GPU compute
    local pkgs=(
        base-devel                 # gcc, make, cmake, …
        git curl wget
        level-zero-loader          # Level Zero ICD loader (libze_loader.so)
        intel-compute-runtime      # Intel GPU driver: Level Zero + OpenCL backend
        intel-gmmlib               # GPU memory management library
        intel-graphics-compiler    # Shader compiler (IGC)
        ocl-icd                    # Standard OpenCL ICD loader (libOpenCL.so)
        opencl-headers             # OpenCL headers — needed by some custom nodes
    )

    local missing=()
    for pkg in "${pkgs[@]}"; do
        pacman -Q "$pkg" &>/dev/null || missing+=("$pkg")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        log_ok "All required system packages already installed"
    else
        log_info "Installing missing packages: ${missing[*]}"
        sudo pacman -S --noconfirm "${missing[@]}"
        log_ok "System packages installed"
    fi
}

###############################################################################
# 3. Python via uv
###############################################################################
step_python() {
    log_step "Python ${PYTHON_VERSION} (uv-managed)"

    # The uv list output contains e.g. "cpython-3.12.13-linux-x86_64-gnu"
    if uv python list 2>/dev/null | grep -qE "cpython-${PYTHON_VERSION//./\\.}[. -]"; then
        log_ok "Python ${PYTHON_VERSION} already managed by uv"
    else
        log_info "Downloading Python ${PYTHON_VERSION} via uv..."
        uv python install "${PYTHON_VERSION}"
        log_ok "Python ${PYTHON_VERSION} installed"
    fi
}

###############################################################################
# 4. Clone / update ComfyUI
###############################################################################
step_clone_comfyui() {
    log_step "ComfyUI repository"

    if [[ -d "${COMFYUI_DIR}/.git" ]]; then
        log_info "Updating existing clone at ${COMFYUI_DIR}..."
        git -C "${COMFYUI_DIR}" pull --ff-only 2>/dev/null || \
            log_warn "Could not fast-forward — keeping existing checkout"
    else
        if [[ -d "${COMFYUI_DIR}" ]]; then
            read -r -p "[?] ${COMFYUI_DIR} exists but is not a git repo. Re-clone? [y/N] " reply
            [[ "$reply" =~ ^[Yy]$ ]] || die "Aborted by user"
            rm -rf "${COMFYUI_DIR}"
        fi
        log_info "Cloning ComfyUI into ${COMFYUI_DIR}..."
        git clone https://github.com/comfyanonymous/ComfyUI.git "${COMFYUI_DIR}"
    fi

    log_ok "ComfyUI source ready at ${COMFYUI_DIR}"
}

###############################################################################
# 5. Virtual environment
###############################################################################
step_venv() {
    log_step "Virtual environment"
    cd "${COMFYUI_DIR}"

    if [[ -d ".venv/bin" ]]; then
        log_ok "Existing .venv found — skipping creation"
    else
        uv venv .venv --python "${PYTHON_VERSION}"
        log_ok "Created .venv with Python ${PYTHON_VERSION}"
    fi

    # Pin for tools that respect .python-version
    echo "${PYTHON_VERSION}" > .python-version
}

###############################################################################
# 6. PyTorch with native Intel XPU backend
###############################################################################
step_torch_xpu() {
    log_step "PyTorch XPU build (Intel Arc backend)"

    log_info "Installing torch / torchvision / torchaudio from PyTorch XPU wheel index..."
    log_info "Note: --index-url replaces PyPI for this call to get the +xpu variant."
    venv_pip install \
        torch torchvision torchaudio \
        --index-url https://download.pytorch.org/whl/xpu

    log_ok "torch XPU build installed"

    log_info "Verifying XPU device visibility..."
    ONEAPI_DEVICE_SELECTOR="level_zero:gpu" venv_python - <<'PYEOF'
import torch, sys

print(f"  torch version : {torch.__version__}")
print(f"  XPU available : {torch.xpu.is_available()}")

if torch.xpu.is_available():
    count = torch.xpu.device_count()
    print(f"  XPU devices   : {count}")
    for i in range(count):
        print(f"    [{i}] {torch.xpu.get_device_name(i)}")
else:
    print("  XPU devices   : none detected now (may appear after reboot / env reload)")

cuda = torch.cuda.is_available()
print(f"  CUDA available: {cuda}  ← False is EXPECTED for the XPU build")
PYEOF

    echo ""
    if ! ONEAPI_DEVICE_SELECTOR="level_zero:gpu" venv_python -c \
            "import torch; exit(0 if torch.xpu.is_available() else 1)" 2>/dev/null; then
        log_warn "XPU device not visible yet. This can happen when:"
        log_warn "  • Drivers were just installed and need a reboot"
        log_warn "  • ONEAPI_DEVICE_SELECTOR is wrong (try 'level_zero:0')"
        log_warn "  • Group membership for /dev/dri needs re-login"
        log_warn "Installation continues — XPU should be visible at runtime."
    fi
}

###############################################################################
# 7. Intel Extension for PyTorch (IPEX) — optional
###############################################################################
step_ipex() {
    log_step "Intel Extension for PyTorch (IPEX) — optional"
    log_info "IPEX adds Intel-specific XPU optimisations (not required to run ComfyUI)."

    # IPEX must match the installed torch version; Intel's wheel index handles this.
    # Lunar Lake (Xe2) support in IPEX is ongoing — failure here is non-fatal.
    if venv_pip install intel-extension-for-pytorch \
            --extra-index-url "https://pytorch-extension.intel.com/release-whl/stable/xpu/us/" \
            2>/dev/null; then
        log_ok "IPEX installed"
    else
        log_warn "IPEX not available for this torch/Python combination — skipping"
        log_warn "ComfyUI will use native torch.xpu without IPEX optimisations"
    fi
}

###############################################################################
# 8. ComfyUI Python dependencies
###############################################################################
step_comfyui_deps() {
    log_step "ComfyUI Python dependencies"
    cd "${COMFYUI_DIR}"
    [[ -f requirements.txt ]] || die "requirements.txt not found — clone may be incomplete"

    # Strip torch* lines from requirements before installing to prevent pip/uv from
    # replacing our XPU build with a CUDA/CPU build pulled from the default PyPI index.
    local tmp_reqs
    tmp_reqs=$(mktemp --suffix=.txt)
    grep -vE "^\s*(torch|torchvision|torchaudio)" requirements.txt > "$tmp_reqs"

    log_info "Installing ComfyUI deps (torch family handled separately)..."
    venv_pip install -r "$tmp_reqs"
    rm -f "$tmp_reqs"

    log_ok "ComfyUI dependencies installed"
}

###############################################################################
# 9. Launch scripts
###############################################################################
step_launch_scripts() {
    log_step "Launch scripts"

    # ── launch.sh ────────────────────────────────────────────────────────────
    cat > "${COMFYUI_DIR}/launch.sh" << 'LAUNCHEOF'
#!/usr/bin/env bash
# ComfyUI launcher — Intel Arc / Lunar Lake XPU
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Select Intel GPU via Level Zero.
# Override by setting ONEAPI_DEVICE_SELECTOR before calling this script.
export ONEAPI_DEVICE_SELECTOR="${ONEAPI_DEVICE_SELECTOR:-level_zero:gpu}"

source .venv/bin/activate

echo "[ComfyUI] PyTorch XPU check:"
python - << 'PYEOF'
import torch
xpu = torch.xpu.is_available()
print(f"  torch {torch.__version__}  |  XPU={xpu}  |  CUDA={torch.cuda.is_available()} (False=correct for XPU build)")
if xpu:
    for i in range(torch.xpu.device_count()):
        print(f"  Device [{i}]: {torch.xpu.get_device_name(i)}")
PYEOF

echo ""
echo "[ComfyUI] Starting → http://localhost:8188"
exec python main.py \
    --listen 0.0.0.0 \
    --port 8188 \
    --preview-method auto \
    --use-pytorch-cross-attention \
    "$@"
LAUNCHEOF

    chmod +x "${COMFYUI_DIR}/launch.sh"
    log_ok "Created ${COMFYUI_DIR}/launch.sh"

    # ── launch-cpu.sh ─────────────────────────────────────────────────────────
    cat > "${COMFYUI_DIR}/launch-cpu.sh" << 'CPUEOF'
#!/usr/bin/env bash
# ComfyUI CPU fallback launcher (for debugging)
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
source .venv/bin/activate
echo "[ComfyUI] CPU mode (no GPU acceleration)"
exec python main.py --listen 0.0.0.0 --port 8188 --cpu "$@"
CPUEOF

    chmod +x "${COMFYUI_DIR}/launch-cpu.sh"
    log_ok "Created ${COMFYUI_DIR}/launch-cpu.sh (CPU fallback)"
}

###############################################################################
# 10. Summary
###############################################################################
step_summary() {
    echo ""
    echo -e "${GREEN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  ComfyUI installed — Intel Arc Lunar Lake (XPU)         ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    cat << SUMMARY
  Location  : ${COMFYUI_DIR}
  Python    : ${PYTHON_VERSION}  (uv-managed)
  Backend   : Intel XPU via Level Zero  ← NOT CUDA, by design

  ${BOLD}Launch:${NC}
    cd ${COMFYUI_DIR} && ./launch.sh
    Open: http://localhost:8188

  ${BOLD}Troubleshoot XPU:${NC}
    cd ${COMFYUI_DIR}
    source .venv/bin/activate
    ONEAPI_DEVICE_SELECTOR=level_zero:gpu \\
      python -c "import torch; print('XPU:', torch.xpu.is_available())"

    # If still False, try device index 0 explicitly:
    ONEAPI_DEVICE_SELECTOR=level_zero:0 \\
      python -c "import torch; print(torch.xpu.is_available())"

    # List DRI devices:
    ls -la /dev/dri/

  ${BOLD}Common question — "torch not compiled with CUDA":${NC}
    torch.cuda.is_available() → False   CORRECT for the XPU build
    torch.xpu.is_available()  → True    Your GPU is working via XPU

  ${BOLD}Model directories:${NC}
    ${COMFYUI_DIR}/models/checkpoints/
    ${COMFYUI_DIR}/models/loras/
    ${COMFYUI_DIR}/models/vae/
    ${COMFYUI_DIR}/custom_nodes/

SUMMARY
}

###############################################################################
# Main
###############################################################################
main() {
    echo -e "${BOLD}${BLUE}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ComfyUI Installer — Intel Arc / Lunar Lake / CachyOS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${NC}"

    step_preflight
    step_system_packages
    step_python
    step_clone_comfyui
    step_venv
    step_torch_xpu
    step_ipex
    step_comfyui_deps
    step_launch_scripts
    step_summary
}

main "$@"
