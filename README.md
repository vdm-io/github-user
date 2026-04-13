## Github User Setup

![Test](https://github.com/vdm-io/github-user/actions/workflows/test.yml/badge.svg)

We use this action to setup a github user on the Ubuntu systems in the Github Actions Workflows.

### How To

You will need to setup a list of secrets in your account. You can do this per/repository or per/organization.

> The github user email being used to build
- GIT_EMAIL

> The github username being used to build
- GIT_USER

> gpg -a --export-secret-keys >myprivatekeys.asc
> The whole key file text from the above myprivatekeys.asc
> This key must be linked to the github user being used
- GPG_KEY

> The name of the myprivatekeys.asc user
- GPG_USER

> A id_ed25519 ssh private key linked to the github user account
- SSH_KEY

> A id_ed25519.pub ssh public key linked to the github user account
- SSH_PUB

All these secret values are needed to fully automate the setup to easy interact with gitHub.

Optionally you can also set:

> A github personal access token for CLI use
- GIT_TOKEN

### Workflows

In your workflows action script you will need to add the following as an example:

```yaml
jobs:
  build:
    runs-on: [ubuntu-latest]
    steps:
      - name: Setup gitHub User Details
        uses: vdm-io/github-user@v2
        with:
          gpg-key: ${{ secrets.GPG_KEY }}
          gpg-user: ${{ secrets.GPG_USER }}
          ssh-key: ${{ secrets.SSH_KEY }}
          ssh-pub: ${{ secrets.SSH_PUB }}
          git-user: ${{ secrets.GIT_USER }}
          git-email: ${{ secrets.GIT_EMAIL }}

      - name: Clone Master Repository
        run: |
          /bin/git clone git@github.com:[org]/[repo].git [folder]

      - name: Do your actions
        run: |
          cd [folder]
          /bin/bash ./src/run.sh
```

#### With a Personal Access Token

```yaml
      - name: Setup gitHub User Details
        uses: vdm-io/github-user@v2
        with:
          gpg-key: ${{ secrets.GPG_KEY }}
          gpg-user: ${{ secrets.GPG_USER }}
          ssh-key: ${{ secrets.SSH_KEY }}
          ssh-pub: ${{ secrets.SSH_PUB }}
          git-user: ${{ secrets.GIT_USER }}
          git-email: ${{ secrets.GIT_EMAIL }}
          git-token: ${{ secrets.GIT_TOKEN }}
```

#### With RSA Keys

If you are using RSA keys instead of ed25519, pass the `ssh-type` input:

```yaml
      - name: Setup gitHub User Details
        uses: vdm-io/github-user@v2
        with:
          gpg-key: ${{ secrets.GPG_KEY }}
          gpg-user: ${{ secrets.GPG_USER }}
          ssh-key: ${{ secrets.SSH_KEY }}
          ssh-pub: ${{ secrets.SSH_PUB }}
          git-user: ${{ secrets.GIT_USER }}
          git-email: ${{ secrets.GIT_EMAIL }}
          ssh-type: 'rsa'
```

### Inputs

| Input       | Required | Default       | Description                                           |
|-------------|----------|---------------|-------------------------------------------------------|
| `gpg-key`   | Yes      |               | ASCII-armored GPG private key for commit/tag signing  |
| `gpg-user`  | Yes      |               | GPG user ID (name or email) to locate the signing key |
| `ssh-key`   | Yes      |               | SSH private key content                               |
| `ssh-pub`   | Yes      |               | SSH public key content (must match the private key)   |
| `git-user`  | Yes      |               | Git commit author name                                |
| `git-email` | Yes      |               | Git commit author email                               |
| `git-token` | No       | `''`          | GitHub personal access token (stored for CLI use)     |
| `ssh-type`  | No       | `ed25519`     | SSH key type: `ed25519`, `rsa`, or `ecdsa`            |
| `ssh-host`  | No       | `github.com`  | SSH host to configure                                 |
| `force`     | No       | `false`       | Overwrite existing config for a different user        |

### Re-run Behavior

The setup script is designed to run once. On subsequent runs:

- **Same user**: the script detects the existing SSH key matches and skips setup entirely. No files are modified. Exit 0.
- **Different user**: the script refuses with an error and tells you to use `--force`.
- **Different user + `--force`**: the script removes the existing protected files and reconfigures for the new user.

```yaml
      - name: Setup gitHub User Details
        uses: vdm-io/github-user@v2
        with:
          gpg-key: ${{ secrets.GPG_KEY }}
          gpg-user: ${{ secrets.GPG_USER }}
          ssh-key: ${{ secrets.SSH_KEY }}
          ssh-pub: ${{ secrets.SSH_PUB }}
          git-user: ${{ secrets.GIT_USER }}
          git-email: ${{ secrets.GIT_EMAIL }}
          force: 'true'
```

### Testing

The test suite lives at `tests/test-setup-git.sh`. It generates real GPG and SSH keys, runs the setup script, and verifies that git operations actually work afterward. No GitHub account or network access is needed — all git operations are local and `ssh-keyscan` is mocked for offline use.

Tests run automatically on every push to master, on every pull request, and can be triggered manually from the Actions tab.

#### Running Locally

```bash
bash tests/test-setup-git.sh ./src/setup.sh
```

#### What The Tests Cover

- **Argument validation** — missing args, empty values, invalid key types, unknown flags
- **Full setup** — file creation, permissions, SSH config content, git config values
- **SSH keypair validation** — mismatched keys are rejected, matching keys with comments are accepted
- **Idempotency** — re-running with the same user skips setup, no files are modified
- **Force reconfigure** — different user is rejected without `--force`, accepted with it
- **Git commit signing** — signed commits and signed tags are created and verified in a real git repo
- **SSH type override** — RSA and other key types write to the correct paths
- **Token handling** — token file is always created for backward compatibility, even when empty
- **Security** — no temporary key files left on disk, chmod 400 files are protected
- **Argument syntax** — both `--key value` and `--key=value` forms work
- **Custom SSH host** — `--ssh-host` writes the correct host into the SSH config block
- **Help flag** — `-h` and `--help` show usage text and document `--force`

#### Test Output

When all tests pass you will see:

```
setup-git.sh — Test Suite
...
════════════════════════════════════════
Tests run:    89
Passed:       89
Failed:       0

ALL TESTS PASSED
```

Any failure will show exactly what was expected vs what was received, making it easy to diagnose regressions.

### Legacy Usage

If you prefer to call the script directly instead of using the action:

```yaml
      - name: Setup gitHub User Details
        env:
          GIT_USER: ${{ secrets.GIT_USER }}
          GIT_EMAIL: ${{ secrets.GIT_EMAIL }}
          GPG_USER: ${{ secrets.GPG_USER }}
          GPG_KEY: ${{ secrets.GPG_KEY }}
          SSH_KEY: ${{ secrets.SSH_KEY }}
          SSH_PUB: ${{ secrets.SSH_PUB }}
        run: |
          /bin/bash <(/bin/curl -s https://raw.githubusercontent.com/vdm-io/github-user/v2/src/setup.sh) --gpg-key "$GPG_KEY" --gpg-user "$GPG_USER" --ssh-key "$SSH_KEY" --ssh-pub "$SSH_PUB" --git-user "$GIT_USER" --git-email "$GIT_EMAIL"
```

### Free Software

```txt
Llewellyn van der Merwe <github@vdm.io>
Copyright (C) 2019. All Rights Reserved
GNU/GPL Version 2 or later - http://www.gnu.org/licenses/gpl-2.0.html
```
