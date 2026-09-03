# Deployment With systemd

This guide describes a simple production setup for `agent-daemon` on a Linux
host with `systemd`.

## Deployment Model

The intended layout is one `systemd` instance per team, department, or
workflow:

- Unit name: `agent-daemon@<instance>.service`
- Config file: `<install_dir>/configs_decrypted/<instance>.yml`
- Message directory: configured per instance via `message_dir`
- Logs: `journalctl -u agent-daemon@<instance>`

The template unit shipped with the gem lives at
`examples/deploy/agent-daemon@.service` and starts the daemon with the config
file matching the `%i` instance name.

## Prerequisites

- Linux host with `systemd`
- Ruby and Bundler installed
- Claude Code or OpenCode installed for the service user
- A deployment directory owned by that user, for example
  `/home/deploy/agent-daemon`

If your configs contain secrets, keep them encrypted in git and decrypt them
into `configs_decrypted/` during deploy.

## Recommended Server Layout

```text
/home/deploy/agent-daemon/
  bin/agent-daemon
  vendor/bundle/
  configs_decrypted/
    support.yml
    sales.yml
  prompts/
    support.txt
    sales.txt
  to_message/
    support/
      sent/
    sales/
      sent/
```

Each instance should use its own `message_dir`. When running under `systemd`,
set `logging.output: stdout` so logs go to `journald`.

## 1. Prepare The Install Directory

Check out your deployment repo or application repo into the target directory,
then install the gem and generate a binstub:

```bash
cd /home/deploy/agent-daemon
bundle install --deployment --path vendor/bundle
bundle binstubs agent_daemon --path bin
mkdir -p configs_decrypted prompts to_message/support/sent
```

The generated `bin/agent-daemon` path matches the bundled `systemd` template.

## 2. Create Per-Instance Configs

Create one config per instance:

```yaml
project_path: /home/deploy/my-agent-project
message_dir: to_message/support

tracker:
  token: "your-oauth-token"
  org_id: "your-cloud-org-id"

runners:
  - name: triage
    backend: claude
    agent: task-analyst
    prompt_template: prompts/support.txt
    trigger:
      type: tracker
      query: 'Queue: SUPPORT AND Status: "Open"'
      interval: 300

messenger:
  interval: 30
  webhook_url: "https://chat.example.com/hooks/support"
  # Or use the mattermost transport with a bot token (keep it in ENV, see
  # docs/secrets.md):
  #   type: mattermost
  #   base_url: "https://chat.example.com"
  #   token: <%= secret('MM_BOT_TOKEN') %>
  #   team: support
  #   default_channel: alerts

logging:
  level: info
  output: stdout
```

Save this as `/home/deploy/agent-daemon/configs_decrypted/support.yml`.

Repeat the same pattern for other instances, for example `sales.yml` or
`devops.yml`.

## 3. Install The systemd Unit

Render the template with the actual service user and install directory:

```bash
SERVICE_USER=deploy
INSTALL_DIR=/home/deploy/agent-daemon

sed \
  -e "s|__USER__|${SERVICE_USER}|g" \
  -e "s|__DIR__|${INSTALL_DIR}|g" \
  examples/deploy/agent-daemon@.service \
  | sudo tee /etc/systemd/system/agent-daemon@.service > /dev/null

sudo systemctl daemon-reload
```

The resulting unit starts instance `support` with:

```text
/home/deploy/agent-daemon/bin/agent-daemon /home/deploy/agent-daemon/configs_decrypted/support.yml
```

## 4. Enable And Start Instances

Enable the required instances:

```bash
sudo systemctl enable --now agent-daemon@support.service
sudo systemctl enable --now agent-daemon@sales.service
```

Common operations:

```bash
sudo systemctl restart agent-daemon@support.service
sudo systemctl stop agent-daemon@support.service
sudo systemctl status agent-daemon@support.service
journalctl -u agent-daemon@support.service -f
```

### Restarting one entity instead of the whole unit

When the supervisor runs with a console configured, `systemctl restart` is no
longer the only lever. Each supervised entity — every runner, each workflow's
Messenger, and the global Mattermost reactor — has a **Restart** button on its
console detail page, reachable without SSH by anyone in `allowed_groups`. Roles
are validated but do not gate the action in v1: any allowed user can restart any
entity.

What to expect when you press it:

- The restart is **cooperative, not a kill.** The entity is asked to stop and is
  respawned only after it returns; a runner mid-agent-run finishes tearing that
  run down first. Expect the respawn itself to wait out the fixed 60-second
  restart delay, so a normal restart takes roughly a minute end to end.
- The control disables itself and the entity reads `restarting` until the new
  generation is live. Past `60s + restart_warning_margin_seconds` (default 5) a
  warning appears. It is a hint that the restart is slow, not proof it failed.
- **Restarting the Mattermost reactor is fleet-wide.** There is one reactor per
  process for every workflow, so its restart disconnects and reconnects every
  workflow's Mattermost listeners. The console routes that action through a
  confirmation page for this reason. Restarting a *Mattermost runner* is not
  fleet-wide: only its file-poll consumer restarts, and its listener inside the
  shared reactor is untouched.
- Each accepted restart writes one line to the journal naming the operator and
  the target generation, so `journalctl -u agent-daemon@support.service` is where
  you find out who restarted what. The console's own activity log is in-memory
  and does not survive a supervisor restart.

`systemctl restart` remains the right tool for config changes, upgrades, and
anything that must reload the process itself.

## 5. Deploy Updates

A typical deploy is:

1. Update the checkout in `<install_dir>`.
2. Run `bundle install --deployment --path vendor/bundle`.
3. Refresh `configs_decrypted/<instance>.yml` if configs changed.
4. Restart the affected instances with `systemctl restart`.

Example:

```bash
cd /home/deploy/agent-daemon
git pull
bundle install --deployment --path vendor/bundle
bundle binstubs agent_daemon --path bin
sudo systemctl restart agent-daemon@support.service
```

If you maintain encrypted configs in git, decrypt them as part of step 3 before
restarting the service.

## Troubleshooting

- Service does not start: inspect `journalctl -u agent-daemon@<instance> --since 10m`
- Prompt template path errors: verify paths are relative to the config file
  directory, not the current shell directory
- No webhook messages: check for stuck `.yml` or `.yaml` files in `message_dir`
- Multiple instances interfere with each other: make sure each config uses a
  unique `message_dir`
