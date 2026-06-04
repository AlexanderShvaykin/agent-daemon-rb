# Secrets in config.yml

`config.yml` is rendered as an **ERB template** before it is parsed as YAML
(`File.read → ERB.new(src).result(binding) → YAML.safe_load`, in
`lib/agent_daemon/config.rb`). This lets the config stay readable plaintext
while secret *values* live in the process environment, so you no longer have to
encrypt the whole file just to protect a token.

A config with no ERB tags renders byte-identically and parses exactly as
before — this is fully backward compatible.

## Referencing secrets

Two forms are available in the ERB binding:

### `secret('KEY')` — recommended

```yaml
tracker:
  token: <%= secret('TRACKER_TOKEN') %>
messenger:
  webhook_url: <%= secret('WEBHOOK_URL') %>
  # or, for the mattermost transport, the bot access token:
  # token: <%= secret('MM_BOT_TOKEN') %>
```

The `mattermost` messenger transport authenticates with a Mattermost/Loop bot
access token. Treat it like any other secret — resolve it via
`token: <%= secret('MM_BOT_TOKEN') %>` rather than inlining it, and provision it
through the same `sops exec-env` flow described below.

`secret('KEY')`:

- reads `ENV.fetch('KEY')` and **fails fast** with a `ConfigError` naming the
  key when the variable is unset (consistent with the eager config validation);
- JSON-encodes the value (`.to_json`), producing a double-quoted, escaped
  string that is always a valid YAML scalar — so tokens and URLs containing
  YAML-significant characters (`#`, `:`, `?`, `&`, quotes) are preserved intact
  rather than truncating or corrupting the parse.

### Raw `<%= ENV['KEY'] %>` — lenient, author's discretion

```yaml
tracker:
  org_id: <%= ENV['TRACKER_ORG_ID'] %>
```

Plain ERB access to `ENV` stays available for lenient resolution (an unset
variable yields nil/empty rather than raising) or for interpolating non-secret
values. With raw ENV you own the quoting.

## Populating the environment

The daemon is **sops-agnostic**: it never reads, decrypts, or knows about sops
or any secrets file. Populating `ENV` is the operator's concern. A common
pattern is to let sops inject secrets into the process environment for the
duration of the run:

```bash
sops exec-env secrets.enc.yml -- bin/agent-daemon config.yml
```

Any other mechanism that sets the environment variables (a systemd
`EnvironmentFile`, a CI secret store, `export`, etc.) works equally well.

## Trust note: `safe_load` vs. ERB

`YAML.safe_load` still guards the parsed *data*. ERB, however, can execute
arbitrary Ruby, which shifts trust to the config *file itself*. This is
acceptable because the config author **is** the server operator — the file is
already trusted. Treat `config.yml` with the same care as any executable
deployment artifact, and do not render untrusted config through the daemon.
