#!/bin/bash
# Boots rootless containerd (+ snapshotter + BuildKit) as a non-root user
# inside an UNPRIVILEGED container, then runs the given command.
#
#   As ENTRYPOINT:           rootless-init.sh <cmd...>
#   In GitLab before_script: source /usr/local/bin/rootless-init.sh
#
# Hard requirement: unprivileged user namespaces must be usable inside the
# container (host kernel + the runner's seccomp/AppArmor settings).
# Optional devices: /dev/fuse  -> fast fuse-overlayfs snapshotter
#                   /dev/net/tun -> usermode networking + port mapping
set -e

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"

# Data root for images/snapshots/build cache. Override this to relocate all
# state, e.g. onto the /builds emptyDir on the Kubernetes executor.
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
mkdir -p "$XDG_DATA_HOME"

log() { echo ">> $*" >&2; }

# ---- 1. sanity check: can we create user namespaces at all? ---------------
if ! unshare --user --map-root-user true 2>/dev/null; then
    echo "!! Cannot create user namespaces in this container."            >&2
    echo "!! The host kernel must allow unprivileged userns and the"      >&2
    echo "!! runner must not block it. Ask the admin to add (NOT"         >&2
    echo "!! privileged) to the [runners.docker] section of config.toml:" >&2
    echo '!!   security_opt = ["seccomp=unconfined", "apparmor=unconfined"]' >&2
    exit 1
fi

# ---- 2. snapshotter: fuse-overlayfs if /dev/fuse exists, else native ------
if [ -z "$CONTAINERD_SNAPSHOTTER" ]; then
    if [ -c /dev/fuse ]; then
        CONTAINERD_SNAPSHOTTER=fuse-overlayfs
    else
        CONTAINERD_SNAPSHOTTER=native
        log "no /dev/fuse -> using slow 'native' snapshotter." \
            "Ask the runner admin for: devices = [\"/dev/fuse\"]"
    fi
fi
export CONTAINERD_SNAPSHOTTER

FUSE_SOCK="$XDG_RUNTIME_DIR/containerd-fuse-overlayfs.sock"
if [ "$CONTAINERD_SNAPSHOTTER" = "fuse-overlayfs" ] && \
   [ ! -f "$HOME/.config/containerd/config.toml" ]; then
    # register the fuse-overlayfs proxy plugin (must exist before containerd starts)
    mkdir -p "$HOME/.config/containerd"
    cat > "$HOME/.config/containerd/config.toml" <<EOF
version = 2
[proxy_plugins."fuse-overlayfs"]
  type = "snapshot"
  address = "$FUSE_SOCK"
EOF
fi

# ---- 3. networking: tap-based usermode net needs /dev/net/tun -------------
# Without it, fall back to rootlesskit host networking: build/pull/push all
# work; 'nerdctl run -p' port publishing does not (use --net=host instead).
if [ -z "$CONTAINERD_ROOTLESS_ROOTLESSKIT_NET" ] && [ ! -c /dev/net/tun ]; then
    export CONTAINERD_ROOTLESS_ROOTLESSKIT_NET=host
    export CONTAINERD_ROOTLESS_ROOTLESSKIT_PORT_DRIVER=none
    log "no /dev/net/tun -> rootlesskit host networking." \
        "For full networking ask the admin for: devices = [\"/dev/net/tun\"]"
fi

# helper: run a command inside the rootlesskit namespaces
nsenter_child() {
    nsenter -U --preserve-credentials -m -n \
        -t "$(cat "$XDG_RUNTIME_DIR/containerd-rootless/child_pid")" -- "$@"
}

# ---- 4. start rootless containerd ------------------------------------------
if ! nerdctl info >/dev/null 2>&1; then
    containerd-rootless.sh >"$HOME/containerd-rootless.log" 2>&1 &
    ok=
    for _ in $(seq 1 30); do
        sleep 1
        nerdctl info >/dev/null 2>&1 && { ok=1; break; }
    done
    if [ -z "$ok" ]; then
        echo "!! rootless containerd failed to start; last log lines:" >&2
        tail -n 50 "$HOME/containerd-rootless.log" >&2
        exit 1
    fi

    if [ "$CONTAINERD_SNAPSHOTTER" = "fuse-overlayfs" ]; then
        nsenter_child containerd-fuse-overlayfs-grpc "$FUSE_SOCK" \
            "$XDG_DATA_HOME/containerd-fuse-overlayfs" \
            >"$HOME/fuse-overlayfs.log" 2>&1 &
    fi
fi

# ---- 5. start BuildKit (needed for 'nerdctl build') ------------------------
export BUILDKIT_HOST="${BUILDKIT_HOST:-unix://$XDG_RUNTIME_DIR/buildkit/buildkitd.sock}"
if ! buildctl debug workers >/dev/null 2>&1; then
    mkdir -p "$XDG_RUNTIME_DIR/buildkit"
    nsenter_child buildkitd --addr "$BUILDKIT_HOST" \
        --root "$XDG_DATA_HOME/buildkit" \
        --oci-worker=false \
        --containerd-worker=true \
        --containerd-worker-namespace=default \
        --containerd-worker-snapshotter="$CONTAINERD_SNAPSHOTTER" \
        --containerd-worker-net=host \
        >"$HOME/buildkitd.log" 2>&1 &
    for _ in $(seq 1 30); do
        buildctl debug workers >/dev/null 2>&1 && break
        sleep 1
    done
    buildctl debug workers >/dev/null 2>&1 || \
        log "WARNING: buildkitd not ready, 'nerdctl build' may fail (see ~/buildkitd.log)"
fi

log "ready (snapshotter=$CONTAINERD_SNAPSHOTTER net=${CONTAINERD_ROOTLESS_ROOTLESSKIT_NET:-usermode})"

# when used as ENTRYPOINT, run the CI job command
if [ "$#" -gt 0 ]; then
    exec "$@"
fi
