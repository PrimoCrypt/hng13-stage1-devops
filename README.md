 # deploy.sh — Remote Docker App Deployment

**Purpose**

`deploy.sh` is a single-file, production-minded Bash script that automates cloning a Git repository, preparing a remote Linux host (installing Docker, Docker Compose, and Nginx), transferring the application, running it in Docker (either via `docker-compose` or `Dockerfile`), creating an Nginx reverse proxy, validating the deployment, rotating logs, and providing an idempotent `--cleanup` option.

This README explains how to use the script, which environment and security considerations to keep in mind, and troubleshooting tips.

---

## Quick summary (TL;DR)

1. Make the script executable: `chmod +x deploy.sh`
2. Run it and answer prompts: `./deploy.sh`
3. Or run cleanup: `./deploy.sh --cleanup`
4. Check logs in `./logs/deploy_YYYYMMDD_HHMMSS.log`

---

## Prerequisites (local machine)

* Bash (POSIX-compatible shell)
* `git`, `rsync`, `ssh`, `ssh-keygen` (installed locally)
* Valid SSH key that can log into the remote host
* Network access (firewall rules permitting SSH and later HTTP)

## Assumptions about the repository

* The repository root contains **either** a `docker-compose.yml` (preferred) **or** a `Dockerfile`.
* If `docker-compose.yml` exists, the script will use `docker compose` commands. If only `Dockerfile` exists, the script builds and runs a single container.
* The application listens on a container-internal port you provide at the prompt (e.g. `3000`). Nginx will proxy HTTP -> that port.

---

## High-level workflow

1. Collect required parameters (repo URL, PAT if required, branch, remote user/host, SSH key path, app internal port)
2. Clone the repository (or pull if already present) into a timestamped local workspace
3. Validate presence of Dockerfile / docker-compose.yml
4. Test SSH connectivity
5. Perform a dry-run `rsync` to preview files to be transferred
6. Run bootstrap commands on remote: update packages, install Docker, Docker Compose, and Nginx if missing
7. Create `/opt/<repo-name>` on remote and `rsync` project files into it
8. Build + run the application (docker compose or docker build/run)
9. Create or overwrite an Nginx site config at `/etc/nginx/sites-available/<app>.conf` and symlink it into `sites-enabled`
10. Test nginx configuration and reload
11. Validate services (docker, nginx, container health, simple HTTP tests)
12. Final idempotency tidy: prune images/networks, remove exited containers older than X days
13. Archive local logs and rotate older ones
14. Optional `--cleanup` mode removes containers, images, nginx configs, and remote `/opt/<app>` directories (requires explicit typed confirmation)

---

## Usage

### Interactive mode (recommended)

```bash
chmod +x deploy.sh
./deploy.sh
```

Follow the prompts for:

* Git repository URL (HTTPS or SSH)
* (Optional) PAT for private HTTPS repos
* Branch (defaults to `main`)
* Remote SSH username
* Remote SSH host/IP
* Local path to SSH private key to use for remote login
* Internal application port (container port)

The script logs all actions to `./logs/deploy_YYYYMMDD_HHMMSS.log`.

### Cleanup mode

To remove the deployed resources (destructive):

```bash
./deploy.sh --cleanup
```

You will be prompted to type `CLEANUP` (uppercase) to confirm. The script then connects to the remote and attempts best-effort removal of containers, images, nginx configs, and deployed directories.

---

## Environment variables (optional)

You can pre-fill prompts by exporting environment variables before running the script. The script will use these if present:

* `GIT_REPO_URL` - git clone URL
* `GIT_PAT` - Personal Access Token (used only for HTTPS cloning)
* `BRANCH` - branch to checkout (default `main`)
* `REMOTE_USER` - SSH username
* `REMOTE_HOST` - SSH host/IP
* `SSH_KEY_PATH` - local private key to use for remote SSH
* `APP_PORT` - internal application port

Example:

```bash
export GIT_REPO_URL="git@github.com:me/my-app.git"
export REMOTE_USER=ubuntu
export REMOTE_HOST=198.51.100.42
export SSH_KEY_PATH=~/.ssh/deploy_key
export APP_PORT=3000
./deploy.sh
```

---

## Security & best practices

* **Never** commit or paste your PAT or private SSH key into the repository. Use environment variables or a secure secrets manager if automating runs.
* The script uses `ssh -o StrictHostKeyChecking=no` to simplify first-time connections — for production, add the host to known hosts or remove that flag.
* Nginx configuration created by the script uses `server_name _;` by default. Replace with a real domain and add proper TLS using Certbot or another CA before going public.
* The script uses `sudo` for privileged actions on the remote; ensure the user has `sudo` rights.

---

## Idempotency notes

* `rsync --delete` is used when syncing to the remote; this ensures the remote mirror matches the local working copy and avoids stale files.
* `docker compose down` or `docker rm -f` is performed before starting a new container to avoid name collisions.
* Nginx symlink creation uses `ln -sf` to overwrite safely.
* Cleanup and prunes are best-effort and guarded to avoid accidental deletion of unrelated resources, but **do inspect** the generated commands before running in sensitive environments.

---

## Troubleshooting

* **SSH fails**: Verify network ACLs, firewall rules, and that the SSH key matches. Try `ssh -i <key> <user>@<host> -v` for verbose output.
* **rsync issues**: Ensure `rsync` exists on both sides and the `SSH_KEY_PATH` is readable.
* **Docker build fails**: Check the Dockerfile context and dependencies. Use the log file produced by this script to see remote output.
* **App not reachable**: Check container logs (`docker logs <name>`), confirm app listens on the expected internal port, and that Nginx is proxying to the correct port.
* **Nginx test fails**: Run `sudo nginx -t` on remote; the script performs this automatically and logs its output.

---

## Logging

Logs are created in `./logs/deploy_<TIMESTAMP>.log`. On script exit, the log is compressed (`.gz`) and older compressed logs are rotated (default retention: 30 days). If gzip or find are unavailable, the script will continue but will skip compression/rotation.

---

## Recommended enhancements (future)

* Add automatic SSL provisioning (Certbot + LetsEncrypt) with domain validation.
* Integrate health-check endpoints and wait-for-start logic with retries and exponential backoff.
* Add a non-interactive mode for CI/CD use with required flags and secure PAT/secret injection.
* Support deployment to multiple hosts and blue/green deployments with traffic switching.

---

## License & Attribution

This script and README are provided as-is. Review, adapt, and audit before using in production. No warranty.

---

## Want changes?

Tell me what to change (more safety checks, different defaults, add TLS automation, CI-friendly flags). I’ll update the script and README accordingly.
