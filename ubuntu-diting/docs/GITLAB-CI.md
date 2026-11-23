# GitLab CI migration — assessment and open items (2026-11-23)

Question: can the kernel / rootfs / initramfs be built from zero in
GitLab CI, without the interactive build-server loop?

## Verdict

The core chain is CI-ready (deterministic, scripted, verified):
sources -> kernel -> packages -> rootfs -> initramfs -> boot -> verify.
Five gaps must be closed first, and the from-zero path itself must be
re-proven with one clean manual run — the long-lived work/ tree on the
build server hides drift (the initramfs fsck flake of 2026-11-23 was
exactly this class).

## What works

- make sources / kernel: prepare-kernel.sh locks tag+patches+config by
  digest; incremental and reproducible (.diting-stamp).
- make packages: explicit versions (build-packages.sh, device 0.7.33).
- make rootfs: build-rootfs.sh (debootstrap, chroot, qemu-user path).
- make initramfs + make boot: hooks travel in the device package;
  FSTYPE=ext4 made the fsck inclusion deterministic.
- make verify: 35 host-side assertions incl. ramdisk content (fsck
  binaries, serial rescue hook) and rootfs e2fsprogs.
- make repro-check, make qemu-test exist (see gap 5).

## Open items

1. Owner firmware blobs: `make firmware` consumes owner-supplied
   closed blobs. CI needs them as Secure Files / package registry
   artifacts. Largest external dependency.
2. Kernel package signing (signer FPR in the manifest): inject the GPG
   key as a CI variable or add an unsigned build path.
3. Runner image: pin aarch64 cross toolchain + qemu-aarch64-static +
   debootstrap in a Dockerfile kept in the repo.
4. From-zero purity is unguarded: add a scheduled job running
   `make clean && make image && make verify` so the from-zero path is
   continuously proven (this catches the work/-tree drift class).
5. qemu-test is the only boot-level smoke gate (an initramfs that
   hangs at root mount would time out red) but is unproven — revive
   and wire it before trusting the pipeline.

## Skeleton

    stages: [sources, kernel, packages, rootfs, images, verify]
    kernel:   make sources && make kernel          (artifacts: output/debs)
    packages: make packages
    rootfs:   make rootfs                          (privileged runner: debootstrap/loop)
    images:   make initramfs && make boot
    verify:   make verify                          (gate)

Plus a scheduled full-rebuild job (item 4) and, once revived, qemu-test
in the verify stage.

Recommended next step before any CI work: one manual
`make clean && make image && make verify` run on the build server to
flush out stale-path issues; then the migration is low-risk.
