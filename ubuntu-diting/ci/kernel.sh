#!/bin/bash
# The kernel development container of ubuntu-diting. ci/Dockerfile.kernel is
# the image: the toolchain of `make sources` and `make kernel`, and what
# inspects a built kernel. This drives it; ci/KERNEL.md has the details.
#
#   ci/kernel.sh build                  build the image for this checkout
#   ci/kernel.sh up                     start the container, the checkout at /src
#   ci/kernel.sh shell                  a bash in the running container, as this user
#   ci/kernel.sh exec <command...>      one command in the running container, as this user
#   ci/kernel.sh make [VAR=v...] target...
#                                       a Makefile target, in tmux inside the container
#   ci/kernel.sh run <command...>       any command, the same way (a script, a long analysis)
#   ci/kernel.sh log                    the end of the last command and the exit statuses
#   ci/kernel.sh down                   remove the container
#
# docker is $DOCKER on the host: DOCKER="sudo docker" where this user is not
# in the docker group.
set -euo pipefail

UD="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOP="$(cd "$UD/.." && pwd)"
DOCKER="${DOCKER:-docker}"

# $DOCKER may be more than one word ("sudo docker"): run it as such.
# shellcheck disable=SC2086
docker() { $DOCKER "$@"; }
NAME="${KERNEL_CONTAINER:-diting-kernel}"
# make in one tmux session, anything else in another: an analysis or a fetch
# can run while a build is on.
SESSION_BUILD=k50ultra-build
SESSION_RUN=k50ultra-run
LOG_DIR=output/logs

die() { echo "ERROR: $*" >&2; exit 1; }

image() {
	local rev
	rev="$(git -C "$TOP" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
	echo "diting-kernel:$rev"
}

as_user=(--user "$(id -u):$(id -g)")

running() { docker container inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null | grep -q true; }

need_image() {
	docker image inspect "$(image)" >/dev/null 2>&1 ||
		die "no image $(image): run ci/kernel.sh build"
}

need_up() {
	running || die "container $NAME is not running: run ci/kernel.sh up"
}

cmd_build() {
	docker build -t "$(image)" -f "$UD/ci/Dockerfile.kernel" \
		--build-arg "VCS_REF=$(git -C "$TOP" rev-parse HEAD)" "$UD/ci"
}

cmd_up() {
	need_image
	if running; then
		echo "$NAME is already running (ci/kernel.sh down, then up, to start it on a new image)"
		return
	fi
	docker rm -f "$NAME" >/dev/null 2>&1 || true
	docker run -d --name "$NAME" --network=host \
		-e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)" -v "$TOP:/src" "$(image)"
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
	# the way through docker exec and tmux. The words are the caller's.
	# It is tmux's own -e that hands them to the new session, not the
	# environment of docker exec: a session created while a tmux server is
	# already running inherits that server's environment, and with it the
	# command of whichever session started the server (two makes in one
	# tree).
	docker exec -d "${as_user[@]}" -w /src/ubuntu-diting "$NAME" \
		tmux new-session -d -s "$session" \
			-e "DITING_MAKE=$*" -e "DITING_MAKE_LOG=$log" diting-kernel-make ||
		die "cannot start: tmux session $session exists in $NAME (a command is running there; ci/kernel.sh log)"
	echo "started in $NAME, session $session: $*"
	echo "log: ubuntu-diting/$log (ci/kernel.sh log)"
}

cmd_make() {
	need_up
	[ $# -gt 0 ] || die "make needs a target"
	local log name
	name="$(printf '%s' "${*: -1}" | tr -c 'A-Za-z0-9._-' '-')"
	case " $* " in
		*' dtbs-check '*)
			# build-dtbs.sh takes dtschema from tools/venv of the checkout.
			docker exec "${as_user[@]}" -w /src/ubuntu-diting "$NAME" bash -c '
				[ -x tools/venv/bin/dt-validate ] && exit 0
				python3 -m venv tools/venv
				tools/venv/bin/pip install --quiet --no-index --find-links /opt/wheels dtschema'
			;;
	esac
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
		[ -z "$pane" ] || printf '--- tmux %s:\n%s\n' "$session" "$pane"
	done
	docker exec "${as_user[@]}" -w /src/ubuntu-diting "$NAME" \
		sh -c "grep -H '^EXIT=' $LOG_DIR/*.log 2>/dev/null | tail -5" || true
}

cmd_down() {
	docker rm -f "$NAME" >/dev/null
}

case "${1:-}" in
	build) cmd_build ;;
	up) cmd_up ;;
	shell) cmd_shell ;;
	exec) shift; cmd_exec "$@" ;;
	make) shift; cmd_make "$@" ;;
	run) shift; cmd_run "$@" ;;
	log) cmd_log ;;
	down) cmd_down ;;
	*)
		sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
		exit 1
		;;
esac
