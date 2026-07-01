# OffGrid Platform

Automated build pipeline for the OffGrid penetration testing VM.

## Quick start

Clone the repo, set up the build machine, build.

    git clone git@github.com:YOUR_USERNAME/offgrid-platform.git
    cd offgrid-platform
    sudo bash setup-build-machine.sh
    # log out and back in
    cd full/build && ./build.sh 1.0.0

## Structure

    lean/           Headless Kali, terminal only, ~10GB VMDK
    full/           Full GUI Kali, XFCE desktop, ~27GB VMDK
    common/         Shared scripts
    setup-build-machine.sh   One-time setup, Fedora and Debian/Ubuntu

## Variants

| Variant | Description | Size |
|---------|-------------|------|
| Lean | Headless, terminal only, reverse tunnel | ~10GB |
| Full | XFCE desktop, full Kali toolset, BloodHound CE | ~27GB |

## Releasing a new version

    cd full/build
    ./build.sh 1.1.0
