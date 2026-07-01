# =============================================================================
# OffGrid — Packer build config (QEMU/KVM)
# Produces: output/OffGrid-v0.1.0.qcow2
#
# DO NOT run directly — use build.sh which handles IP detection automatically
# =============================================================================

packer {
  required_version = ">= 1.9.0"
  required_plugins {
    qemu = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

# ── Variables ─────────────────────────────────────────────────────────────────

variable "version" {
  type    = string
  default = "0.3.0"
}

variable "kali_iso_url" {
  type    = string
  default = "https://cdimage.kali.org/current/kali-linux-2026.1-installer-netinst-amd64.iso"
}

variable "kali_iso_checksum" {
  type    = string
  default = "sha256:caf5ff7d7a4f73c85a6f1688300b936d3d7fd6965c52d80632e36709a09255a7"
}

variable "vm_memory" {
  type    = number
  default = 4096
}

variable "vm_cpus" {
  type    = number
  default = 4
}

variable "disk_size" {
  type    = string
  default = "64G"
}

variable "host_ip" {
  type    = string
  default = "10.95.208.144"   # managed by build.sh — do not edit manually
}

variable "http_port" {
  type    = number
  default = 8100
}

variable "ssh_username" {
  type    = string
  default = "kali"
}

variable "ssh_password" {
  type      = string
  default   = "kali"
  sensitive = true
}

# ── Source ────────────────────────────────────────────────────────────────────

source "qemu" "offgrid" {
  vm_name          = "OffGrid-v${var.version}"
  iso_url          = var.kali_iso_url
  iso_checksum     = var.kali_iso_checksum

  # Hardware
  memory           = var.vm_memory
  cpus             = var.vm_cpus
  disk_size        = var.disk_size
  disk_interface   = "virtio"
  net_device       = "virtio-net"
  format           = "qcow2"

  # KVM acceleration
  accelerator      = "kvm"

  # SSH
  ssh_username     = var.ssh_username
  ssh_password     = var.ssh_password
  ssh_timeout      = "90m"
  ssh_port         = 22

  # Set to false to watch the VM window during build
  headless         = true

  # HTTP server — serves preseed.cfg to the VM
  http_directory    = "http"
  http_bind_address = "0.0.0.0"
  http_port_min     = var.http_port
  http_port_max     = var.http_port

  # Boot
  boot_wait        = "5s"
  boot_command = [
    "<wait3>",
    "<down><wait1>",
    "<tab><wait2>",
    " preseed/url=http://${var.host_ip}:${var.http_port}/preseed.cfg",
    " auto=true",
    " priority=critical",
    " locale=en_US",
    " keymap=us",
    " hostname=offgrid",
    " domain=local",
    "<wait>",
    "<enter>"
  ]

  # Output
  output_directory = "output"

  shutdown_command = "echo '${var.ssh_password}' | sudo -S shutdown -P now"
}

# ── Build ─────────────────────────────────────────────────────────────────────

build {
  name    = "offgrid"
  sources = ["source.qemu.offgrid"]

  # Step 1 — upload bootstrap.sh
  provisioner "file" {
    source      = "../bootstrap.sh"
    destination = "/tmp/bootstrap.sh"
  }

  # Step 2 — run bootstrap
  provisioner "shell" {
    inline = [
      "echo '${var.ssh_password}' | sudo -S bash /tmp/bootstrap.sh",
    ]
    timeout = "60m"
  }

  # Step 3 — verify tools
  provisioner "shell" {
    inline = [
      "echo '--- Verifying tools ---'",
      "which nmap      && nmap --version | head -1",
      "which netexec   && netexec --version | head -1",
      "which ffuf      && ffuf -V",
      "which nuclei    && nuclei -version",
      "ls /opt/wordlists/",
      "ls /engagements/",
      "echo '--- Verification complete ---'",
    ]
  }

  # Step 4 — clean up
  provisioner "shell" {
    inline = [
      "rm -f /tmp/bootstrap.sh",
      "echo '${var.ssh_password}' | sudo -S apt-get clean",
      "echo '${var.ssh_password}' | sudo -S rm -rf /var/lib/apt/lists/*",
      "cat /dev/null > ~/.bash_history",
      "cat /dev/null > ~/.zsh_history 2>/dev/null || true",
    ]
  }

  # Step 5 — stamp version
  provisioner "shell" {
    inline = [
      "echo 'OFFGRID_VERSION=${var.version}' | sudo -S tee /etc/offgrid-release",
      "echo 'BUILD_DATE='$(date -u +%Y-%m-%dT%H:%M:%SZ) | sudo -S tee -a /etc/offgrid-release",
      "cat /etc/offgrid-release",
    ]
  }

  # Manifest
  post-processor "manifest" {
    output     = "output/OffGrid-v${var.version}-manifest.json"
    strip_path = true
  }
}
