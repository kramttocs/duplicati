# Duplicati Docker 'By Label' Stop/Start Script

This setup allows Duplicati to temporarily stop selected Docker containers before a backup starts, then restart only those same containers after the backup completes.

Created to reduce the chance of file locking, inconsistent backups, or corruption when backing up active container data.

There are three parts to this setup:

1. **Duplicati** — runs the backup job.
2. **dockerproxy** — gives the Duplicati container controlled access to the Docker API. This is useful when you already use dockerproxy elsewhere and want to avoid mounting the Docker socket directly into Duplicati.
3. **backup script** — stops and starts containers based on Docker labels.

---

## How It Works

Duplicati exposes backup metadata to scripts through environment variables.

This script uses:

| Variable | Purpose |
|---|---|
| `DUPLICATI__backup_name` | The name of the Duplicati backup job |
| `DUPLICATI__EVENTNAME` | The script event, usually `BEFORE` or `AFTER` |
| `DUPLICATI__OPERATIONNAME` | The Duplicati operation, such as `Backup` |

The script then looks for Docker containers with this label:

```yaml
com.example.duplicati.backup: "<Duplicati backup name>"
```

For example, if the Duplicati job is named:

```text
OpenCloud
```

then the matching container label should be:

```yaml
com.example.duplicati.backup: "OpenCloud"
```

During the `BEFORE` event, matching running containers are stopped.

During the `AFTER` event, only containers that were stopped by the `BEFORE` event are started again.

---

## Important Matching Note

The current script uses Docker label matching directly.

That means the label value should match the Duplicati backup name exactly.

Example:

```yaml
labels:
  com.example.duplicati.backup: "OpenCloud"
```

matches a Duplicati job named:

```text
OpenCloud
```

But this would not be treated the same by the current script:

```text
opencloud
OPENCLOUD
oPenCloud
```

For best results, keep the Duplicati backup job name and the label value identical.

Container names themselves do **not** need to match the Duplicati job name. The Duplicati job name only needs to match the Docker label value.

---

## Recommended Folder Layout

Example Duplicati config layout:

```text
/appdata/duplicati/
├── config/
│   └── docker_backup_state/
├── logs/
│   └── docker_backup.log
└── scripts/
    └── stop-start-containers-by-label.sh
```

Inside the Duplicati container, these might be mounted as:

```text
/config
/logs
/scripts
```

---

## dockerproxy

The Duplicati container needs to run Docker commands such as:

```bash
docker ps
docker inspect
docker stop
docker start
```

Instead of mounting the Docker socket directly into the Duplicati container, this setup uses a Docker socket proxy.

This reduces the amount of Docker API access exposed to Duplicati.

### Example dockerproxy Compose Service

```yaml
name: dockerproxy

services:
  socket-proxy:
    image: lscr.io/linuxserver/socket-proxy:latest
    container_name: dockerproxy
    restart: unless-stopped

    ports:
      # Host-only access.
      #Example: Duplicati can use DOCKER_HOST=tcp://127.0.0.1:2375
      #         when Duplicati is running with network_mode: host.
      - 127.0.0.1:2375:2375

    environment:
      - TZ=Etc/UTC
      - LOG_LEVEL=info

      # Needed for Docker CLI connectivity/version negotiation
      - PING=1
      - VERSION=1

      # Needed by the Duplicati script:
      # docker ps, docker inspect
      - CONTAINERS=1

      # Needed by the Duplicati script:
      # docker stop, docker start
      - POST=1
      - ALLOW_START=1
      - ALLOW_STOP=1

      # Everything else disabled
      - AUTH=0
      - BUILD=0
      - COMMIT=0
      - CONFIGS=0
      - DISTRIBUTION=0
      - EVENTS=0
      - EXEC=0
      - IMAGES=0
      - INFO=0
      - NETWORKS=0
      - NODES=0
      - PLUGINS=0
      - SECRETS=0
      - SERVICES=0
      - SESSION=0
      - SWARM=0
      - SYSTEM=0
      - TASKS=0
      - VOLUMES=0

    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro

    read_only: true

    tmpfs:
      - /run
```

### Why `CONTAINERS=1`

The script needs access to container-related Docker API endpoints for:

- listing containers
- inspecting container state
- starting containers
- stopping containers

### Why `POST=1`

Docker start and stop actions require POST requests.

Without this, read-only Docker commands may work, but `docker stop` and `docker start` will fail.

### Security Notes

Do not expose dockerproxy publicly.

---

## Duplicati

The Duplicati container needs:

- access to the backup source paths
- access to the script
- access to the log folder
- access to the script state folder
- Docker CLI available inside the container
- `DOCKER_HOST` pointed at dockerproxy

### Example Duplicati Compose Service

```yaml
services:
  duplicati:
    image: lscr.io/linuxserver/duplicati:latest
    container_name: duplicati
    environment:
      - PUID=99
      - PGID=100
      - TZ=Etc/UTC
      - SETTINGS_ENCRYPTION_KEY=replace-with-a-long-random-secret
      - DOCKER_HOST=tcp://127.0.0.1:2375
    volumes:
      - ./config:/config
      - ./scripts:/scripts
      - /mnt/user/logs/duplicati:/logs
      - /mnt/user/backups/duplicati:/backups
      - /mnt/user/data:/source:ro
      - /usr/bin/docker:/usr/bin/docker:ro
    network_mode: host
    restart: unless-stopped

```


## Backup Script

Save the script as:

```text
/scripts/stop-start-containers-by-label.sh
```

---

## Script Configuration

The script supports these optional environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `BACKUP_LABEL_KEY` | `com.example.duplicati.backup` | Docker label used to match containers to a Duplicati job |
| `LOG_DIR` | `/logs` | Folder where the script log is written |
| `LOG_FILE` | `/logs/docker_backup.log` | Full log file path |
| `STATE_DIR` | `/config/docker_backup_state` | Folder used to remember containers stopped by the `BEFORE` event |

Change these values as appropriate for your environment.

---

## Labeling Containers for Backup Control

Add this label to any container that should be stopped during a specific Duplicati job:

```yaml
labels:
  com.example.duplicati.backup: "OpenCloud"
```

When the `OpenCloud` Duplicati job runs, all matching containers will be stopped before the backup.

Only containers that were actually running and successfully stopped by the script will be restarted afterward.

---

## Configuring Duplicati

In the Duplicati web UI, open the backup job.

Go to:

```text
Options
```

Add these advanced options:

```text
--run-script-before-required=/scripts/stop-start-containers-by-label.sh
--run-script-after=/scripts/stop-start-containers-by-label.sh
```
The `before` script is marked as required so the backup does not continue if Docker cannot be queried or the script cannot establish container state. Individual container stop failures are logged, but the script continues so the `AFTER` event can restart any containers that were already stopped.

The same script is used for both events.

Duplicati sets the event name automatically, so the script knows whether it is running as `BEFORE` or `AFTER`.

---

## Example Backup Flow

For a Duplicati job named:

```text
OpenCloud
```

and a container labeled:

```yaml
labels:
  com.example.duplicati.backup: "OpenCloud"
```

the flow is:

1. Duplicati starts the `Backup` operation.
2. Duplicati runs the script with event `BEFORE`.
3. The script finds containers labeled `com.example.duplicati.backup=OpenCloud`.
4. The script checks whether each matching container is running.
5. Running containers are stopped.
6. The names of stopped containers are saved to a state file.
7. Duplicati performs the backup.
8. Duplicati runs the script with event `AFTER`.
9. The script reads the state file.
10. Only containers listed in the state file are started.
11. The state file is removed after successful restart.

---

## State File Behavior

The script stores state files here by default:

```text
/config/docker_backup_state/
```

Each Duplicati job gets its own state file based on the backup job name.

Example:

```text
/config/docker_backup_state/OpenCloud.stopped
```

This file contains the names of containers that were stopped by the `BEFORE` event.

The state file is removed after the `AFTER` event successfully restarts all containers.

If a restart fails, the state file is kept so the failed restart can be investigated or retried.

---

## Logs

The default log file is:

```text
/logs/docker_backup.log
```

The script also writes to the container log output.

---
