# 🚀 oneclick-n8n — One-File Production Installer for n8n

**oneclick-n8n** is a fully automated **one-file installer** that sets up a complete, production-ready n8n environment on any fresh Ubuntu server.

Just run one command, enter your domain, and you're done.

---

# 🔥 Features

### ✅ **Complete One-Click Setup**
No files to configure. Nothing to edit. This script handles everything.

### ✅ **What It Installs & Configures**
- Docker
- Docker Compose
- PostgreSQL database
- Nginx reverse proxy
- Automatic SSL (Let's Encrypt)
- Production-grade n8n environment
- Daily backups (local + optional S3 sync)
- Auto-generated `.env` with safe secrets
- Firewall hardening (UFW)

### ✅ **Zero additional files required**
This repo contains **just one script** → `install.sh`  
The script generates:
- `docker-compose.yml`
- Nginx config
- Backup system
- Environment variables

---

# 🚀 Quick Start (One Command Install)

Run this on a fresh Ubuntu 20.04/22.04 server:

```bash
curl -sSL https://raw.githubusercontent.com/SaurabhGtr/oneclick-n8n/main/install.sh | sudo bash
