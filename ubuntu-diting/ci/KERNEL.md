# The kernel container

For the kernel alone (`make sources`, `make kernel`, `make dtbs`, and looking
at what was built) nothing has to be installed on the build host: the
toolchain is an image, `ci/Dockerfile.kernel`, and `ci/kernel.sh` drives it.
On the host there is only `git`, `docker`, `rsync` (to receive the patches
from the machine they are written on) and `tmux`: building the image is a
long command like any other and runs in a tmux session.

```sh
export DOCKER="sudo docker"       # where this user is not in the docker group
ubuntu-diting/ci/kernel.sh build     # the image for this checkout: diting-kernel:<rev>
ubuntu-diting/ci/kernel.sh up        # the container diting-kernel, this checkout at /src
ubuntu-diting/ci/kernel.sh make sources
ubuntu-diting/ci/kernel.sh make kernel
ubuntu-diting/ci/kernel.sh log       # the end of the last command, and EXIT=<status>
ubuntu-diting/ci/kernel.sh shell     # a bash in the container, as the same user
ubuntu-diting/ci/kernel.sh exec aarch64-linux-gnu-objdump -d work/kernel-obj/vmlinux   # any command, in /src/ubuntu-diting
ubuntu-diting/ci/kernel.sh down
```

`make` goes into the tmux session `k50ultra-build` inside the container and
`run` into `k50ultra-run`, so they survive the ssh session they were started
from and a fetch or an analysis can run while a build is on; the output is in
`ubuntu-diting/output/logs/make-<target>.log` or `run-<time>.log`, ending in
`EXIT=<status of the command>`. The results are where the scripts always put them
(`ubuntu-diting/output/debs`, `output/kernel`), in the bind-mounted checkout,
owned by the user who started the container.

It is the same base image, pinned by digest, as `ci/Dockerfile` (the
from-zero builder), so a kernel built here is built with the same Debian 13
toolchain as the one the builder image builds.
`/usr/share/diting-kernel-packages.tsv` in the image lists its packages with
their versions.

## Dependencies, by role

All of it is in `ci/Dockerfile.kernel`; this list says what each part is for.

| Role | Debian packages |
| --- | --- |
| Fetch and prepare the source: `make sources`, `prepare-kernel.sh` | `git`, `gnupg` (the signed tag of kernel.lock), `curl`, `ca-certificates`, `rsync` (the patched tree is synced into `work/kernel-src`), `patch` |
| Compile: `build-kernel.sh` | `build-essential` (host `gcc` and `make`), `bc`, `bison`, `flex`, `libssl-dev` (module signing), `libelf-dev` and `libdw-dev` (objtool), `pkg-config` (where kmod looks for modules), `perl`, `python3`, `kmod` (depmod), `cpio` |
| Cross toolchain (the host is x86_64) | `gcc-aarch64-linux-gnu`, `binutils-aarch64-linux-gnu`, `libc6-dev-arm64-cross` |
| Package: `bindeb-pkg` | `dpkg-dev` (dpkg-buildpackage, dpkg-deb; the build dependencies are checked against the image's dpkg database), `debhelper`, `fakeroot` |
| Boot and disk images, if made here | `device-tree-compiler` (dtc, fdtput, fdtget), `mkbootimg` (mkbootimg, unpack_bootimg), `android-sdk-libsparse-utils` (simg2img, img2simg), `xz-utils`, `zstd`, `lz4`, `e2fsprogs` |
| `make dtbs-check` | `python3-venv`; dtschema has no Debian package, so the image carries its wheels in `/opt/wheels` and `ci/kernel.sh make dtbs-check` installs them into `tools/venv` of the checkout |
| Look at a built kernel | `gdb-multiarch`, `crash` (a vmcore), `dwarves` (pahole, BTF), `bpftool` (vmlinux.h, BTF dumps), `sparse`, `python3-pyelftools`, `elfutils`, `binutils-aarch64-linux-gnu` (objdump, readelf, addr2line for arm64) |
| Run an arm64 user-space binary on the host | `qemu-user-static` |
| Inside the container | `tmux`, `sudo` (some scripts call it; as root it asks for nothing), `libncurses-dev` (menuconfig), `file`, `less`, `vim-tiny` |

Not in it, on purpose: what only the rootfs and the package chroots need
(debootstrap, qemu binfmt registration, the arm64 build libraries) — that is
`ci/Dockerfile` — and ccache: `make kernel` is incremental by itself
(`prepare-kernel.sh` re-exports only what a patch changed), and with ccache
in the path a build is no longer the one `docs/BUILD.md` describes.

## The container

- The checkout is bind-mounted at `/src`, which is where the scripts expect
  the tree (`DITING_TOP` in `scripts/lib.sh`). `kernel.sh` mounts the
  checkout it is run from.
- The container runs as root only to create, at start, a user with the uid
  and gid of whoever ran `up` (`diting-kernel-entrypoint`); everything else
  runs as that user (`docker exec --user`), so nothing root-owned is left in
  the checkout.
- `--network=host`, as with the builder image: git, gpg and pip use the
  host's network and resolver as they are. The container is not privileged:
  the kernel targets chroot and mount nothing.
- `up` on a running container does not restart it. After `build` (or a
  change to the checkout under `ci/`), `down` and `up` again; `down` ends
  any make that is running in it.
- The command and the log of a `make` or a `run` reach their tmux session
  through `tmux new-session -e`, never through the environment of
  `docker exec`: a session created while a tmux server is already running
  inherits that server's environment, and with it the command of the session
  that started the server. (Learned the hard way: a second `make kernel`
  in the same tree, stopped with SIGINT and the object directory removed.)

## Boot images from a kernel alone

`make boot` (`scripts/build-boot-image.sh`) wants the initramfs of a built
rootfs (`$WORK/rootfs/boot/initrd.img-$KERNEL_RELEASE`), so a kernel update
that way means a whole rootfs build first. It is not needed for a kernel: the
initramfs the phone boots holds one module, `fuse.ko`, and nothing that
belongs to a kernel build. A pair of images for a new kernel is made in the
container from the kernel, its DTB, that initramfs and the command line, with
the same tool `make boot` uses:

    # inside the container, in /src/ubuntu-diting
    bash packages/device-xiaomi-diting/src/diting-mkbootimg --conf config/diting.conf \
         --kernel output/kernel/Image-7.2.10-diting \
         --initrd work/flash-batch1/initrd.img-7.2.10-diting \
         --dtb output/kernel/sm8475-xiaomi-diting.dtb \
         --cmdline "root=PARTLABEL=userdata ro rootwait allow_mismatched_32bit_el0 diting.debug=usb" \
         --out work/flash-batch1/images --name diting-ubuntu-7.2.10-diting-rootfs

`config/diting.conf` has every variable the tool reads. The initramfs is the
one out of the phone's `vendor_boot_a` on 2026-11-26: the vendor ramdisk of
the image, at byte 4096, as long as the u32 at byte 24 of its `VNDRBOOT`
header (20,678,557 bytes, zstd). `work/` is not in git; when it is gone, take
it from the partition dump again (`device-data/images/<date>/vendor_boot_a.img`).
When the initramfs itself changes (a module of the boot path, a hook), the
rootfs has to be built.

`verify-boot-image.sh` wants the stock images under `device-data/`, which the
build host does not have. What tells the pair apart from the last one is
simpler: a new `vendor_boot.img` that is byte for byte the image in
`vendor_boot_a` means that only `boot.img` has to be written, and a
`boot.img` compared with the last one, the kernel spliced in at byte 4096 (as
long as the u32 at byte 8), shows that nothing else in it moved. That is how
`release/driver-fix-batch1/` was made and checked; its README has the hashes.
The modules of the build are not in either image: the ones a batch changed go
to `/lib/modules/<release>/updates/` with `depmod -a` on the phone, or the
package does it.

## Measured on the first host

Debian 13 x86_64, 15 threads, 26 GiB, docker 29 (2026-11-26): the image
builds in 40 s; `fetch-sources.sh --kernel-only` (the depth-1 clone of
v7.2.10 and the signature check) takes 1 min 35 s; a clean `make kernel`
14 min, the kernel build log without a warning; the one after nine patches
changed six source files 2.5 min, and the `linux-image` package differed
from the one before in exactly those files: the image, `System.map`, and
`msm.ko`, `dispcc-sm8450.ko`, `qcom_battmgr.ko`. The config was the same
as the one of the kernel the phone was running (`/boot/config-*`, one
sha256), so a module built here can stand in for the phone's own under
`/lib/modules/<release>/updates/`.
