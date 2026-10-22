# murk-action

[![GitHub Marketplace](https://img.shields.io/badge/GitHub%20Marketplace-murk--action-2ea44f?logo=github&logoColor=white)](https://github.com/marketplace/actions/murk-action)

Decrypt [murk](https://github.com/interrupted-sh/murk) secrets and inject them
into your GitHub Actions workflow.

## Usage

```yaml
- uses: interrupted-sh/murk-action@v1
  with:
    murk-key: ${{ secrets.MURK_KEY }}
    trusted-signers: ${{ vars.MURK_TRUSTED_SIGNERS }}
```

Workflows that still use `interrupted-inc/murk-action` must switch to `interrupted-sh/murk-action`, because GitHub does not redirect action references after an organization rename.

All decrypted values are written to `$GITHUB_ENV` and masked in logs.
Subsequent steps can use them as regular environment variables.

```yaml
steps:
  - uses: actions/checkout@v4

  - uses: interrupted-sh/murk-action@v1
    with:
      murk-key: ${{ secrets.MURK_KEY }}
      trusted-signers: ${{ vars.MURK_TRUSTED_SIGNERS }}

  - run: echo "connected to $DATABASE_URL"
    # DATABASE_URL is available and its value is masked in logs
```

## Inputs

| Input             | Required | Default  | Description                            |
|-------------------|----------|----------|----------------------------------------|
| `murk-key`        | yes      |          | Age secret key (`AGE-SECRET-KEY-1...`), or a whole grant key file; see [Agent grant keys](#agent-grant-keys) |
| `version`         | no       | `latest` | murk version, 0.10.2 or newer (e.g. `0.14.0`). 0.14 and later need `trusted-signers` or a whole grant key file |
| `vault`           | no       | `.murk`  | Path to vault file                     |
| `tags`            | no       |          | Space-separated tags to filter secrets |
| `trusted-signers` | no       |          | Signers trusted to sign the vault, one per line or comma-separated. Required by murk 0.14 and later; see below |

## murk 0.14 and later

murk 0.14 loads a vault only if a signer that the machine trusts signed it.
A CI runner is a new machine with no trust record, so you must tell murk which
signers to trust. Supply the `trusted-signers` input:

```yaml
- uses: interrupted-sh/murk-action@v1
  with:
    murk-key: ${{ secrets.MURK_KEY }}
    trusted-signers: ${{ vars.MURK_TRUSTED_SIGNERS }}
```

Store the entries in a repository variable, for example
`MURK_TRUSTED_SIGNERS` (Settings → Secrets and variables → Actions →
Variables). Use one line for each teammate whose writes to the vault must load
in CI. To get an entry, each teammate runs this command in the repository:

```sh
murk trust --print-key
```

The command writes the entry to stdout and the signing-key fingerprint to
stderr. An age key's entry has the form `age1…:<verifying key>`. An
ssh-ed25519 key's entry is its public key line. A bare `age1…` recipient is
not a valid entry. The entries contain only public keys, so you can use a
variable for them and the action does not mask them.

The action sets `MURK_TRUSTED_SIGNERS` only for the murk commands that it runs.
Later steps that run murk themselves need the same value, as in the
[murk exec example](#use-with-murk-exec). If `MURK_TRUSTED_SIGNERS` is already
in the job's environment, the action uses it when the input is empty.

Without `trusted-signers`, murk 0.14 does not load the vault and the step
fails. The error tells you to set `trusted-signers`. The step also fails if no
entry matches the vault's signer, or if an entry has the wrong verifying key.
An unsigned vault always fails when you set trusted signers.

murk 0.13 and earlier ignore `trusted-signers`, so you can add the input before
you upgrade.

**Upgrade note:** the whole team must upgrade to murk 0.14 together. murk 0.14
writes vault format 3.0, which murk 0.13 cannot read. murk 0.14 is the current
release, so the default `version: latest` installs it. Set `trusted-signers` or
use a whole grant key file as `murk-key`, or pin `version: '0.13.0'` until your
team upgrades.

### Agent grant keys

You can give CI a grant key that reads only the secrets it needs, instead of
a teammate's key. Mint it and write the key file to stdout:

```sh
murk agent grant --name ci --only DATABASE_URL --ttl 30d --out -
```

Paste the whole output into the secret that you supply as `murk-key`,
including the comment lines:

```
# murk-trusted-signer: age1…:<verifying key>
# murk-grant-id: ci
# murk-grant-expires: 2026-11-20T12:00:00Z
AGE-SECRET-KEY-1…
```

The action gives the key file to murk unchanged and masks the
`AGE-SECRET-KEY-1` line. The comment lines contain only public data. The
`# murk-trusted-signer:` lines name the signers that the grant trusts, so a
grant key file does not need `trusted-signers`. murk refuses the grant after
the earlier of the key file's expiry and the vault's grant record.

A bare `AGE-SECRET-KEY-1` grant line still works, but then you must set
`trusted-signers`, only the vault's record limits the grant, and murk shows a
warning.

`trusted-signers` adds signers to the signers in the key file. It cannot remove
one. When you revoke a teammate, mint the grant again so that its key file no
longer names them. Run the same `murk agent grant` command with `--renew`,
replace the secret, and remove their entry from `trusted-signers`. Renew the
grant the same way before it expires. To end CI's access, run
`murk agent revoke ci`.

## Examples

### Pin a version

```yaml
- uses: interrupted-sh/murk-action@v1
  with:
    murk-key: ${{ secrets.MURK_KEY }}
    version: '0.14.0'
    trusted-signers: ${{ vars.MURK_TRUSTED_SIGNERS }}
```

### Custom vault path

```yaml
- uses: interrupted-sh/murk-action@v1
  with:
    murk-key: ${{ secrets.MURK_KEY }}
    trusted-signers: ${{ vars.MURK_TRUSTED_SIGNERS }}
    vault: 'prod.murk'
```

### Filter by tags

```yaml
- uses: interrupted-sh/murk-action@v1
  with:
    murk-key: ${{ secrets.MURK_KEY }}
    trusted-signers: ${{ vars.MURK_TRUSTED_SIGNERS }}
    tags: 'deploy aws'
```

### Use with murk exec

If you prefer subprocess injection over `$GITHUB_ENV`:

```yaml
- uses: interrupted-sh/murk-action@v1
  with:
    murk-key: ${{ secrets.MURK_KEY }}
    trusted-signers: ${{ vars.MURK_TRUSTED_SIGNERS }} # murk 0.14 and later

- run: murk exec --vault .murk -- ./deploy.sh
  env:
    MURK_KEY: ${{ secrets.MURK_KEY }}
    MURK_TRUSTED_SIGNERS: ${{ vars.MURK_TRUSTED_SIGNERS }} # murk 0.14 and later
```

## How it works

1. Downloads the murk binary from GitHub Releases for the runner platform and verifies its checksum and build-provenance signature
2. Runs `murk export` to decrypt the vault, with `MURK_TRUSTED_SIGNERS` set from `trusted-signers` when given
3. Masks each secret value with `::add-mask::`
4. Writes each key-value pair to `$GITHUB_ENV`

## Supported runners

- `ubuntu-latest` (x86_64, arm64)
- `macos-latest` (x86_64, arm64)

## Security

- `murk-key` should always come from a GitHub Actions secret
- All decrypted values are masked before being written anywhere
- The murk binary is downloaded over HTTPS from GitHub Releases
- The step fails if the binary's build-provenance signature is missing or invalid, so murk-action requires murk 0.10.2 or newer (older releases are not signed)
- No secrets are written to disk

## License

MIT OR Apache-2.0
