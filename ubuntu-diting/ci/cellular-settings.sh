#!/bin/bash
# The Cellular Settings build container of ubuntu-diting:
# ci/Dockerfile.cellular-settings is the image - the Ubuntu suite of the rootfs
# on arm64, with the Rust toolchain and the GTK 4 development files of
# config/packages-cellular-settings.list - and this drives it. On the phone
# itself, where the result is tried, as ci/ffmpeg.sh does the ffmpeg; on an
# arm64 build host for `make cellular-settings`; on another architecture under
# qemu-user, which needs the binfmt entry of the host and has not been tried.
# The container is not privileged: it builds in work/ and output/ of the
# checkout and chroots nowhere. packages/cellular-settings/README.md has the
# details.
#
#   ci/cellular-settings.sh build                  build the image for this checkout
#   ci/cellular-settings.sh up                     start the container, the checkout at /src
#   ci/cellular-settings.sh down                   remove the container
#   ci/cellular-settings.sh shell                  a bash in the running container, as this user
#   ci/cellular-settings.sh exec <command...>      one command in the running container, as this user
#   ci/cellular-settings.sh once <command...>      the same, and wait for the command to end
#   ci/cellular-settings.sh make [VAR=v...] target...
#                                                  a Makefile target, in tmux inside the container
#   ci/cellular-settings.sh run <command...>       any command, the same way
#   ci/cellular-settings.sh log                    the end of the last command and the exit statuses
#
# docker is $DOCKER on the host: DOCKER="sudo docker" where this user is not
# in the docker group (on the phone: DOCKER="sudo -n docker"). The image is
# diting-cellular-settings:<commit>; without a git checkout (a partial tree
# copied to the phone) set REV.
set -euo pipefail

UD="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOP="$(cd "$UD/.." && pwd)"
DOCKER="${DOCKER:-docker}"
REV="${REV:-$(git -C "$TOP" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)}"

# $DOCKER may be more than one word ("sudo docker"): run it as such.
# shellcheck disable=SC2086
docker() { $DOCKER "$@"; }
NAME="${CELLULAR_SETTINGS_CONTAINER:-diting-cellular-settings}"
# make in one tmux session, anything else in another.
SESSION_BUILD=k50ultra-cellular-settings
SESSION_RUN=k50ultra-cellular-settings-run
LOG_DIR=output/logs

die() { echo "ERROR: $*" >&2; exit 1; }

image() { echo "diting-cellular-settings:$REV"; }

as_user=(--user "$(id -u):$(id -g)")
# The image is the arm64 one; on another architecture docker emulates it.
platform=()
[ "$(uname -m)" = aarch64 ] || platform=(--platform linux/arm64)

running() { docker container inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null | grep -q true; }

need_image() {
	docker image inspect "$(image)" >/dev/null 2>&1 ||
		die "no image $(image): run ci/cellular-settings.sh build"
}

need_up() {
	running || die "container $NAME is not running: run ci/cellular-settings.sh up"
}

cmd_build() {
	# The context holds the three files the Dockerfile copies, and nothing
	# else: the tree has work/ and output/ in it, which are not to be sent.
	local context="$UD/work/cellular-settings-context"
	mkdir -p "$context"
	cp "$UD/ci/Dockerfile.cellular-settings" "$UD/ci/diting-kernel-entrypoint" \
		"$UD/ci/diting-kernel-make" "$context/"
	cp "$UD/config/packages-cellular-settings.list" "$context/"
	docker build "${platform[@]}" -t "$(image)" -f "$context/Dockerfile.cellular-settings" \
		--build-arg "VCS_REF=$(git -C "$TOP" rev-parse HEAD 2>/dev/null || echo "$REV")" "$context"
}

cmd_up() {
	need_image
	if running; then
		echo "$NAME is already running (ci/cellular-settings.sh down, then up, to start it on a new image)"
		return
	fi
	docker rm -f "$NAME" >/dev/null 2>&1 || true
	docker run -d --name "$NAME" "${platform[@]}" --network=host \
		-e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)" -v "$TOP:/src" "$(image)"
}

cmd_down() {
	docker rm -f "$NAME" >/dev/null
}

cmd_shell() {
	need_up
	# No `exec` here: it would look docker up in PATH and skip the function.
	docker exec -it "${as_user[@]}" -w /src/ubuntu-diting "$NAME" bash
}

cmd_exec() {
	need_up
	[ $# -gt 0 ] || die "exec needs a command"
	docker exec "${as_user[@]}" -w /src/ubuntu-diting "$NAME" "$@"
}

# Start a command in the tmux session $1 inside the container, its output in $2.
start() { # session, log, command...
	local session="$1" log="$2"
	shift 2
	# The command goes in as one string: nothing has to survive quoting on
	# the way through docker exec and tmux. It is tmux's own -e that hands
	# them to the new session: a session created while a tmux server is
	# already running inherits that server's environment (ci/KERNEL.md).
	docker exec -d "${as_user[@]}" -w /src/ubuntu-diting "$NAME" \
		tmux new-session -d -s "$session" \
			-e "DITING_MAKE=$*" -e "DITING_MAKE_LOG=$log" diting-kernel-make ||
		die "cannot start: tmux session $session exists in $NAME (a command is running there; ci/cellular-settings.sh log)"
	echo "started in $NAME, session $session: $*"
	echo "log: ubuntu-diting/$log (ci/cellular-settings.sh log)"
}

cmd_make() {
	need_up
	[ $# -gt 0 ] || die "make needs a target"
	local log name
	name="$(printf '%s' "${*: -1}" | tr -c 'A-Za-z0-9._-' '-')"
	start "$SESSION_BUILD" "$LOG_DIR/make-$name.log" make "$@"
}

cmd_run() {
	need_up
	[ $# -gt 0 ] || die "run needs a command"
	start "$SESSION_RUN" "$LOG_DIR/run-$(date -u +%Y%m%dT%H%M%SZ).log" "$@"
}

cmd_log() {
	need_up
	local session pane
	for session in "$SESSION_BUILD" "$SESSION_RUN"; do
		pane="$(docker exec "${as_user[@]}" "$NAME" tmux capture-pane -p -t "$session" 2>/dev/null |
			grep -v '^$' | tail -25 || true)"
		[ -z "$pane" ] || printf -- '--- tmux %s:\n%s\n' "$session" "$pane"
	done
	docker exec "${as_user[@]}" -w /src/ubuntu-diting "$NAME" \
		sh -c "grep -H '^EXIT=' $LOG_DIR/*.log 2>/dev/null | tail -5" || true
}

case "${1:-}" in
	build) cmd_build ;;
	up) cmd_up ;;
	down) cmd_down ;;
	shell) cmd_shell ;;
	exec) shift; cmd_exec "$@" ;;
	once) shift; cmd_exec "$@" ;;
	make) shift; cmd_make "$@" ;;
	run) shift; cmd_run "$@" ;;
	log) cmd_log ;;
	*)
		sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
		exit 1
		;;
esac
