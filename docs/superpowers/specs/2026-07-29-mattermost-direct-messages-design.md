# Mattermost direct-message trigger design

## Goal

Allow a Mattermost runner to accept direct messages from an explicit allowlist
of users. Direct messages do not require an `@` mention. Existing channel
mention behaviour remains unchanged.

## Configuration

`trigger.direct_users` is an optional, non-empty list of Mattermost usernames:

```yaml
trigger:
  type: mattermost
  base_url: "https://chat.example.com"
  token: <%= secret('MM_BOT_TOKEN') %>
  team: your-team-slug
  channels:
    - support
  direct_users:
    - alexander.shvaykin
```

`channels` remains required and governs public and private team channels.
`direct_users` governs only one-to-one direct-message channels. Omitting it
preserves the current mention-only behaviour.

## Event filtering

For every `posted` event, the listener first rejects posts written by the bot
and malformed events, as it does today. It then selects exactly one route:

1. For `channel_type: "D"`, accept only when `sender_name` is listed in
   `direct_users`. Do not require an `@` mention or a team/channel match.
2. For every other channel type, retain the current checks: configured team,
   allowlisted channel name, and bot mention.

The listener continues to de-duplicate accepted post ids across inbox, done,
and failed directories. Accepted direct messages use the existing work-item
format, so `Runner::Mattermost` and the Mattermost transport reply into the
same direct-message channel using `channel_id` and `root_id`.

## Validation and compatibility

When present, `direct_users` must be a non-empty list of non-empty strings.
Invalid values fail configuration loading with a clear `trigger.direct_users`
error. No runner without `direct_users` changes behaviour.

## Documentation and tests

The architecture and example config will describe the optional direct-message
allowlist and its no-mention semantics.

Listener tests will cover:

- an allowlisted user can trigger a direct message without mentioning the bot;
- a non-allowlisted direct-message sender is ignored;
- a direct message from an allowlisted user does not bypass the normal channel
  rules for non-DM posts;
- existing mention and de-duplication tests keep passing.

## Scope boundary

This change only provides generic, allowlisted incoming DM support in the gem.
It does not add an assistant runner, prompts, or production configuration to a
deployment repository.
