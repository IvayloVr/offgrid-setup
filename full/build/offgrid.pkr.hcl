# =============================================================================
# OffGrid Full — Packer build config (QEMU/KVM)
# Produces: output/OffGrid-Full-v1.0.0.qcow2 + .vmdk
#
# Full Kali desktop with GUI, all tools pre-installed, zero internet required
# after deployment.
#
# DO NOT run directly — use build.sh
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
  default = "1.0.0"
}

variable "kali_iso_url" {
  type    = string
  # Full installer — not netinst
  default = "https://cdimage.kali.org/current/kali-linux-2026.2-installer-amd64.iso"
}

variable "kali_iso_checksum" {
  type    = string
  default = "sha256:6dbefacc95e3b556c19c48e8bae39b8b505e2d3a1aba0bfb7ab62b036c3d2ba3"
}

variable "vm_memory" {
  type    = number
  # More RAM during build — full toolset installation needs headroom
  default = 8192
}

variable "vm_cpus" {
  type    = number
  default = 4
}

variable "disk_size" {
  type    = string
  # 120GB — full toolset + Docker images + wordlists
  default = "120G"
}

variable "host_ip" {
  type    = string
  default = "10.111.23.108"
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

source "qemu" "offgrid_full" {
  vm_name          = "OffGrid-Full-v${var.version}"
  iso_url          = var.kali_iso_url
  iso_checksum     = var.kali_iso_checksum

  # Hardware
  memory           = var.vm_memory
  cpus             = var.vm_cpus
  disk_size        = var.disk_size
  disk_interface   = "virtio"
  net_device       = "virtio-net"
  format           = "qcow2"

  # KVM
  accelerator      = "kvm"

  # SSH
  ssh_username     = var.ssh_username
  ssh_password     = var.ssh_password
  # Full install + all tools takes much longer — generous timeout
  ssh_timeout      = "180m"
  ssh_port         = 22

  # Headless — full installer is slower, watch via VNC if needed
  headless         = false

  # Preseed HTTP server
  http_directory    = "http"
  http_bind_address = "0.0.0.0"
  http_port_min     = var.http_port
  http_port_max     = var.http_port

  # Boot — same boot command as lean version, works for full ISO too
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

  output_directory = "output"

  shutdown_command = "echo '${var.ssh_password}' | sudo -S shutdown -P now"
}

# ── Build ─────────────────────────────────────────────────────────────────────

build {
  name    = "offgrid_full"
  sources = ["source.qemu.offgrid_full"]

  # Step 1 — upload bootstrap.sh
  provisioner "file" {
    source      = "../bootstrap.sh"
    destination = "/tmp/bootstrap.sh"
  }

  # Step 2 — run bootstrap
  provisioner "shell" {
    # Wait 30s after SSH connects for filesystem to fully mount
    pause_before = "30s"
    inline = [
      "echo '${var.ssh_password}' | sudo -S bash /tmp/bootstrap.sh",
    ]
    timeout = "120m"
  }

  # Step 3 — verify key tools
  provisioner "shell" {
    inline = [
      "echo '--- Verifying tools ---'",
      "which nmap        && nmap --version | head -1",
      "which netexec     && netexec --version | head -1",
      "which msfconsole  && msfconsole --version",
      "which ffuf        && ffuf -V",
      "which nuclei      && nuclei -version",
      "which burpsuite   || echo 'burpsuite: check manually'",
      "docker --version",
      "ls /opt/wordlists/",
      "ls /engagements/",
      "cat /etc/offgrid-release",
      "echo '--- Verification complete ---'",
    ]
  }

  # Step 4 — clean up build artifacts (keep apt cache for offline use)
  provisioner "shell" {
    inline = [
      "rm -f /tmp/bootstrap.sh",
      # Do NOT run apt-get clean — we keep the package cache for offline reinstalls
      "echo '${var.ssh_password}' | sudo -S rm -rf /var/lib/apt/lists/*",
      "cat /dev/null > ~/.bash_history",
      "cat /dev/null > ~/.zsh_history 2>/dev/null || true",
    ]
  }

  # Manifest
  post-processor "manifest" {
    output     = "output/OffGrid-Full-v${var.version}-manifest.json"
    strip_path = true
  }
}
