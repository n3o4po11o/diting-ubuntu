# The owner image and its SSH key (owner-operated)

The owner image is Ubuntu for the owner's own phone: every local package,
the boot images made inside its own rootfs (`diting.debug=usb` on the kernel
command line, as in every owner build), the account `ubuntu` locked, `sudo`
without a password. `make owner-release` builds it, and the build workflow
(`.github/workflows/build.yml`) builds it on every run and uploads it as the
artifact `diting-<rev>-owner`.

It has **no SSH key**. The runner has none to put in, sshd accepts keys only,
and a locked account cannot unlock the screen either: flashed as it is, the
phone cannot be logged in to. The key goes in after the download, with
`release/add-ssh-key.sh`. That is a local step, on the machine the artifact
was downloaded to: the workflow neither runs the script nor ships it.

State of this on 2026-11-26: the part of the script that works on the image
has run with the real tools on real ext4 images, the small ones of the tests
in `ci/tests.sh` and one of 10 GB with 770 MB of files in it. The part that
calls docker on the host has run against a stand-in for docker only, and an
image it made has not been flashed on a phone. `ci/BUILD.md` has the list of
what has not been verified.

## What is in the artifact

| File | What |
| --- | --- |
| `boot.img`, `vendor_boot.img` | the boot images made inside the owner rootfs |
| `rootfs.img.xz.000`, `.001` | the root filesystem as an Android sparse image, xz-compressed, in parts of 950 MB (about 1.9 GB in all) |
| `flash-diting.sh` | the flash script; it checks the `SHA256SUMS` of its directory |
| `BUILD-INFO`, `PACKAGES.tsv` | when and with what kernel the rootfs was built; its packages |
| `SHA256SUMS` | of the files above |

The artifacts of a run are kept for 14 days.

## What the machine needs

- Linux and docker, usable by the user that runs the script. When docker
  needs sudo, run the script with sudo: the only thing root does on the
  host is to make the new directory the user's.
- About 10 GB free.
- A checkout of this tree, for the script.
- The network, once: the first run builds a small image, `diting-add-key`
  (Debian with e2fsprogs, android-sdk-libsparse-utils and xz-utils).
  `ADD_KEY_IMAGE` names another image with those tools instead, the builder
  image of the artifacts for one.

## Steps

1. Download the artifact `diting-<rev>-owner` of the run (on the page of
   the run, or `gh run download <run> -n diting-<rev>-owner`) and unpack it.
2. Check it, and put the key in:

   ```sh
   cd diting-<rev>-owner
   sha256sum -c --quiet SHA256SUMS && echo OK
   /path/to/diting-ubuntu/ubuntu-diting/release/add-ssh-key.sh ~/diting-mine ~/.ssh/id_ed25519.pub
   ```

   `add-ssh-key.sh --help` prints what the script does.
3. Flash `~/diting-mine`, which now holds the boot images, the rootfs image
   with the key in it, `flash-diting.sh` and a `SHA256SUMS` of its own:

   ```sh
   cd ~/diting-mine && ./flash-diting.sh
   ```

   This erases Android's userdata, as for the public image
   (`release/INSTALL.md`).
4. First login: over the USB network, `ssh ubuntu@172.16.42.1` (the
   computer takes 172.16.42.2). The account has no password, so the screen
   cannot be unlocked until `sudo passwd ubuntu`. The PIN that
   `flash-diting.sh` names at the end is the public image's.

## What the script does

All the work is done in a container, so that nothing can go wrong on the
machine itself.

- On the host, only docker runs, as the user: the script's own checks, then
  one container. The container has no network and is not root (the user's
  own uid), with the directory of the image and the script mounted
  read-only and only the new directory writable. The keys go in on standard
  input: no key file is mounted.
- In the container the image is never mounted. Its files are read and
  written with `debugfs` (e2fsprogs); the filesystem is checked with
  `e2fsck` before and after, and what was written is read back and compared.
- The directory with the artifact is not changed. The directory the script
  writes, DEST, must not exist or be empty.

## Keys

- The artifact has no key, so the keys you give are the keys the phone has.
  More than one: `add-ssh-key.sh DEST key1.pub key2.pub`.
- Keys that are in an image stay, and no key is written twice. A second run
  on the directory the first one wrote adds keys to it. To replace the keys
  of an image that has some, start again from the artifact.
- The public image takes a key the same way: in the `diting-<rev>`
  artifact, put `release-meta/flash-diting.sh` next to `boot.img`,
  `vendor_boot.img` and `rootfs.img.xz.*`, and run the script there.
- On a phone you can already log in to, the keys are in
  `~/.ssh/authorized_keys`, as on any other system.

## When it refuses

The script stops and says why. No image with a key in it comes out of a run
that did not end with `to flash: …`.

| It says | Why |
| --- | --- |
| `no boot.img in …`, `no rootfs.img and no rootfs.img.xz.NNN in …` | not the directory of the artifact: run the script in it |
| `not a public key line in …`, `no public key in …` | a KEYFILE is not a public key: a private key, a damaged or a truncated line |
| `exists and is not an empty directory` | DEST holds something: one image per directory |
| `docker is not installed`, `docker does not answer for this user` | docker is not running, or it needs root on this machine (the user is not in the `docker` group): run the script with sudo |
| `does not match its SHA256SUMS: download it again` | a file of the artifact is not what the workflow packed. The boot images are flashed as they came, so the list is checked before anything else |
| `… has not the tools` | the image of `ADD_KEY_IMAGE` lacks one of the tools, or `diting-add-key` could not be built |
| `is not a clean ext4 filesystem`, `debugfs …`, `… in the image is not …`, `the keys are not in the image as they were written` | the image or the tools did not behave as expected |

When a run fails after DEST was made, the last line names it:
`incomplete: DEST (remove it before trying again)`. What is in it is not to
be flashed.
