# snano 📝

**snano** is a wrapper around your text editor (default: `nano`) that adds:

- Centralized automatic backups before every edit
- Configurable TTL (Time-To-Live) for backups
- Automatic pruning with a systemd user timer
- Easy restore of backups

---

## 🚀 Installation

Clone the repo and run the installer:

```bash
git clone https://github.com/your-username/snano.git
cd snano
./install.sh
```

> Requirements: `bash`, `systemd --user`, `nano` (or another editor configured via config).

---

## ⚙️ Configuration

The user config file is located at:

```
~/.config/snano/config
```

Example (`config/config.example`):

```bash
TTL_HOURS=24     # default TTL for backups (0 = never expire)
EDITOR=nano      # editor to use
```

You can edit this file to customize snano’s behavior.

---

## 🖥️ Usage

### Open a file with backup
```bash
snano file.txt
```

### Main options

- `--ttl HOURS` : set a custom TTL for this backup  
- `-k, --keep`  : keep the backup permanently (ignore TTL)  
- `--list`      : list all registered backups  
- `--prune`     : remove expired backups  
  - `--dry-run` : show what would be deleted without removing  
  - `--force`   : also remove backups marked as permanent  
- `--restore <backup_path> [--to DEST] [--overwrite]`  
- `--restore-latest <original_path> [--to DEST] [--overwrite]`  

---

## 🔄 Automatic pruning

A **systemd user timer** is installed to run `snano --prune` every hour.

Useful commands:

```bash
systemctl --user list-timers | grep snano
systemctl --user status snano-prune.timer
```

---

## 📂 Data structure

- **Config**: `~/.config/snano/config`  
- **Backups**: `~/.local/share/snano/backups/<hostname>/...`  
- **Index**: `~/.local/state/snano/index.tsv`  

---

## 📜 License

MIT
