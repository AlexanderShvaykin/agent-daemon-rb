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
- No webhook messages: check for stuck `.yml` files in `message_dir`
- Multiple instances interfere with each other: make sure each config uses a
  unique `message_dir`
