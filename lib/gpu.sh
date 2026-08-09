#!/bin/bash
# lib/gpu.sh — GPU detection and Docker GPU enablement.
# Sourced by install_dockhub.sh and by the AI provider deploy.sh scripts.
# Not meant to be run directly.
#
# ── THE THREE LAYERS ────────────────────────────────────────────────────
# Most guides conflate these, and the third is the one that actually decides
# whether a container can use your GPU:
#
#   1. Hardware      Is a GPU physically present?        lspci
#   2. Host driver   Can the OS talk to it?              nvidia-smi
#   3. Docker bridge Can CONTAINERS see it?              docker run --gpus all
#
# A machine can pass 1 and 2 and still fail 3 — that's the normal state of a
# fresh install, and it's why "I have an NVIDIA card, why is Ollama on CPU?"
# is such a common question.
#
# ── WHAT THIS FILE WILL AND WON'T DO ────────────────────────────────────
# Layers 1-2 are DETECTED and RECOMMENDED, never installed silently. The
# driver builds a kernel module and needs a reboot, and on a machine with
# Secure Boot enabled it additionally requires interactive MOK enrollment on
# a blue screen during boot — no script can complete that for you. Installing
# it silently would leave a user rebooted into a machine whose driver isn't
# loaded, with nothing explaining why.
#
# Layer 3 (the NVIDIA Container Toolkit) IS installed on request, because it
# is a normal userspace package with no kernel module and no reboot — and it
# is then verified with a real test container rather than assumed.
#
# ── AMD ─────────────────────────────────────────────────────────────────
# NVIDIA first. AMD/ROCm is a later branch of the same detection: Ollama
# already publishes a `rocm` image tag, so the work is in this file rather
# than in every service.

# Set by gpu_detect(). Callers should treat these as read-only.
GPU_VENDOR=""        # nvidia | amd | none
GPU_MODEL=""         # human-readable name from lspci
GPU_DRIVER_OK=0      # layer 2: the host can talk to the GPU
GPU_DOCKER_OK=0      # layer 3: containers can use the GPU  ← the one that matters

# ── Layer 1: is there a GPU at all? ─────────────────────────────────────
_gpu_detect_hardware() {
    GPU_VENDOR="none"
    GPU_MODEL=""
    command -v lspci >/dev/null 2>&1 || return 0

    local line
    line=$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | grep -i nvidia | head -n1 || true)
    if [[ -n "$line" ]]; then
        GPU_VENDOR="nvidia"
        # Strip the "00:00.0 VGA compatible controller: " prefix.
        GPU_MODEL=$(printf '%s' "$line" | sed 's/^[^:]*: //')
        return 0
    fi

    line=$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | grep -iE 'amd|advanced micro devices|radeon' | head -n1 || true)
    if [[ -n "$line" ]]; then
        GPU_VENDOR="amd"
        GPU_MODEL=$(printf '%s' "$line" | sed 's/^[^:]*: //')
    fi
    return 0
}

# ── Layer 2: can the host use it? ───────────────────────────────────────
_gpu_detect_driver() {
    GPU_DRIVER_OK=0
    [[ "$GPU_VENDOR" == "nvidia" ]] || return 0
    command -v nvidia-smi >/dev/null 2>&1 || return 0
    nvidia-smi >/dev/null 2>&1 && GPU_DRIVER_OK=1
    return 0
}

# ── Layer 3: can containers use it? ─────────────────────────────────────
# The only check that actually predicts whether Ollama will use the GPU.
# Tries a small image first: with the toolkit installed, nvidia-smi is
# injected into any container, so a plain ubuntu image is enough and is
# usually already cached. Falls back to NVIDIA's own base image, which is
# the canonical test but a larger pull.
_gpu_detect_docker() {
    GPU_DOCKER_OK=0
    (( GPU_DRIVER_OK )) || return 0
    command -v docker >/dev/null 2>&1 || return 0

    if docker run --rm --gpus all ubuntu:22.04 nvidia-smi >/dev/null 2>&1; then
        GPU_DOCKER_OK=1
    elif docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1; then
        GPU_DOCKER_OK=1
    fi
    return 0
}

# Runs all three layers. Safe to call repeatedly.
gpu_detect() {
    _gpu_detect_hardware
    _gpu_detect_driver
    _gpu_detect_docker
    return 0
}

# ── The snap trap ───────────────────────────────────────────────────────
# Docker installed from snap cannot use the NVIDIA Container Toolkit at all:
# snap's confinement blocks access to /dev/nvidia*. Nothing in the toolkit
# reports this clearly — you just get a GPU that never appears in containers.
# install_dockhub.sh uses the official APT repo, so this only affects people
# who installed Docker themselves beforehand.
gpu_docker_is_snap() {
    local path
    path=$(command -v docker 2>/dev/null || true)
    [[ "$path" == /snap/* ]] && return 0
    snap list docker >/dev/null 2>&1 && return 0
    return 1
}

# ── Reporting ───────────────────────────────────────────────────────────
# Prints what was found and what it means. Callers use this instead of
# writing their own interpretation of the three flags.
gpu_report() {
    if [[ "$GPU_VENDOR" == "none" ]]; then
        print_info "No GPU detected — models will run on the CPU."
        return 0
    fi

    if [[ "$GPU_VENDOR" == "amd" ]]; then
        print_info "AMD GPU detected: $GPU_MODEL"
        print_warn "DockHub's GPU support is NVIDIA-only for now, so this will run on the CPU."
        print_warn "AMD/ROCm is planned — Ollama already publishes a 'rocm' image tag."
        return 0
    fi

    print_info "NVIDIA GPU detected: $GPU_MODEL"

    if (( GPU_DOCKER_OK )); then
        print_info "Containers can use it. ✅ Nothing to do."
        return 0
    fi

    if (( ! GPU_DRIVER_OK )); then
        print_warn "The NVIDIA driver is NOT active on this host (nvidia-smi doesn't work)."
        print_warn "Until it is, the GPU can't be used by anything — container or not."
        echo >&2
        if command -v ubuntu-drivers >/dev/null 2>&1; then
            print_info "Recommended driver for this card:"
            ubuntu-drivers devices 2>/dev/null | grep -E 'recommended' | sed 's/^/    /' >&2 || \
                echo "    (ubuntu-drivers found no recommendation)" >&2
            echo >&2
            print_info "Install it yourself, then reboot:"
            echo "    sudo ubuntu-drivers install" >&2
        else
            print_info "Install the driver for your distribution, then reboot."
        fi
        echo >&2
        print_warn "This is deliberately NOT automated: the driver builds a kernel module"
        print_warn "and needs a reboot, and with Secure Boot on it also needs you to enroll"
        print_warn "a key interactively at boot. A script can't finish that."
        return 0
    fi

    # Driver works, containers can't see the GPU → layer 3 is missing.
    print_warn "The driver works, but containers cannot use the GPU yet."
    print_warn "The NVIDIA Container Toolkit is what bridges that gap."
    if gpu_docker_is_snap; then
        echo >&2
        print_warn "⚠️  Docker appears to be installed from SNAP. The NVIDIA Container"
        print_warn "Toolkit does not work with snap Docker — snap's confinement blocks"
        print_warn "/dev/nvidia*. You'd need to remove the snap and install Docker from"
        print_warn "the official APT repository (install_dockhub.sh does this)."
    fi
    return 0
}

# ── Layer 3 installer ───────────────────────────────────────────────────
# Installs the NVIDIA Container Toolkit and verifies it with a real
# container. Commands follow NVIDIA's current official APT instructions.
# Returns 0 only if a test container could actually see the GPU.
gpu_install_container_toolkit() {
    if ! command -v apt-get >/dev/null 2>&1; then
        print_warn "Automatic toolkit install is only wired up for apt-based systems."
        print_warn "See https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html"
        return 1
    fi
    if gpu_docker_is_snap; then
        print_error "Docker is installed from snap — the NVIDIA Container Toolkit cannot work with it. Reinstall Docker from the official APT repository first."
    fi

    print_info "Adding NVIDIA's package repository..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
        || { print_warn "Could not fetch NVIDIA's signing key."; return 1; }

    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null \
        || { print_warn "Could not add NVIDIA's repository."; return 1; }

    print_info "Installing nvidia-container-toolkit..."
    # Deliberately unpinned. NVIDIA's docs pin an exact version for
    # reproducible builds; a pin baked into this repo would go stale and
    # start failing installs the moment that version leaves the archive.
    sudo apt-get update -qq || { print_warn "apt-get update failed."; return 1; }
    sudo apt-get install -y nvidia-container-toolkit || { print_warn "Package install failed."; return 1; }

    print_info "Configuring the Docker runtime..."
    sudo nvidia-ctk runtime configure --runtime=docker || { print_warn "nvidia-ctk failed."; return 1; }

    # Restarting the daemon restarts every running container with it. That's
    # unavoidable — the new runtime isn't active until it happens — but it
    # should not be a surprise: on a normal DockHub host this briefly takes
    # down NGINX Proxy Manager, Portainer and every deployed service.
    local running
    running=$(docker ps --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' ')
    if (( running > 0 )); then
        print_warn "Restarting Docker now. This briefly stops the $running container(s)"
        print_warn "currently running — including NGINX Proxy Manager and Portainer."
        print_warn "Anything with a restart policy comes back on its own."
    fi
    sudo systemctl restart docker || { print_warn "Could not restart Docker."; return 1; }

    # Verified, not assumed — every step above can succeed and still leave a
    # setup where containers don't get the GPU.
    print_info "Verifying with a test container..."
    _gpu_detect_docker
    if (( GPU_DOCKER_OK )); then
        print_info "✅ Containers can now use the GPU."
        return 0
    fi
    print_warn "The toolkit installed, but a test container still could not see the GPU."
    print_warn "Check: docker run --rm --gpus all ubuntu:22.04 nvidia-smi"
    return 1
}

# ── The one call a service makes ────────────────────────────────────────
# Detects, reports, and — if only layer 3 is missing — offers to fix it.
# Afterwards GPU_DOCKER_OK tells the caller whether to write GPU settings
# into its compose file. Never fails the deploy: CPU is always a valid
# outcome, just a slower one.
gpu_setup() {
    gpu_detect
    gpu_report

    if [[ "$GPU_VENDOR" == "nvidia" ]] && (( GPU_DRIVER_OK )) && (( ! GPU_DOCKER_OK )) && ! gpu_docker_is_snap; then
        local answer
        echo >&2
        read -rp "Install the NVIDIA Container Toolkit now, so containers can use the GPU? (Y/n): " answer
        if [[ "${answer,,}" != "n" ]]; then
            gpu_install_container_toolkit || print_warn "Continuing without GPU support — this service will run on the CPU."
        else
            print_info "Skipped. This service will run on the CPU."
        fi
    fi
    return 0
}
