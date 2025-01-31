#!/usr/bin/env bash

set -eu
set -o pipefail

export INPUTS_JSON="$1"

nixbuildnet_env=""
function add_env() {
  local key="$1"
  local val="$2"
  # Trim existing " or ' quotes
  val="${val%\"}"
  val="${val#\"}"
  val="${val%\'}"
  val="${val#\'}"
  nixbuildnet_env="$nixbuildnet_env $key=\"$val\""
}

# Create a unique invocation id, since there is no way to separate different
# instances of the same job (created with a build matrix). GitHub should really
# expose a "step id" in addition to their run id.
export INVOCATION_ID="$(od -x /dev/urandom | head -1 | awk '{OFS="-"; srand($6); sub(/./,"4",$5); sub(/./,substr("89ab",rand()*4,1),$6); print $2$3,$4,$5,$6,$7$8$9}')"
echo -n "$INVOCATION_ID" > "$HOME/__nixbuildnet_invocation_id"


# Setup known_hosts
SSH_KNOWN_HOSTS_FILE="$(mktemp)"
echo >"$SSH_KNOWN_HOSTS_FILE" \
  eu.nixbuild.net \
  ssh-ed25519 \
  AAAAC3NzaC1lZDI1NTE5AAAAIPIQCZc54poJ8vqawd8TraNryQeJnvH1eLpIDgbiqymM


# Create ssh config
SSH_CONFIG_FILE="$(mktemp)"
cat >"$SSH_CONFIG_FILE" <<EOF
Host eu.nixbuild.net
HostName eu.nixbuild.net
LogLevel ERROR
StrictHostKeyChecking yes
UserKnownHostsFile $SSH_KNOWN_HOSTS_FILE
ControlPath none
EOF


# Setup auth
if [ -n "$NIXBUILD_SSH_KEY" ]; then # SSH key authentication
  ssh_key_file="$(mktemp)"
  printenv NIXBUILD_SSH_KEY > "$ssh_key_file"
  if ssh-keygen -y -f "$ssh_key_file" &>/dev/null; then
    # Start ssh agent
    eval $(ssh-agent)
    # Add ssh key to agent
    ssh-add -q "$ssh_key_file" && rm "$ssh_key_file"
    # Auth agent socket to ssh config
    echo "IdentityAgent $SSH_AUTH_SOCK" >> "$SSH_CONFIG_FILE"
  else
    echo -e >&2 \
"Your SSH key is not a valid OpenSSH private key\n"\
"This is likely caused by one of these issues:\n"\
"* The key has been configured incorrectly in your workflow file.\n"\
"* The workflow was triggered by an actor that has no access to\n"\
"  the GitHub Action secret used for storing your SSH key.\n"\
"  For example, Pull Requests originating from a fork of your\n"\
"  repository can't access secrets."
    exit 1
  fi

elif [ -n "$NIXBUILD_TOKEN" ]; then # Token authentication
  echo "PreferredAuthentications none" >> "$SSH_CONFIG_FILE"
  echo "User authtoken" >> "$SSH_CONFIG_FILE"
  add_env "token" "$NIXBUILD_TOKEN"

else # Invalid auth config
  echo -e >&2 \
"You must one of the settings 'nixbuild_ssh_key' or 'nixbuild_token'\n"\
"It seems like you have configured neither, so nixbuild.net authentication\n"\
"is not possible."
  exit 1
fi


# Setup nixbuild.net settings
for setting in \
  allow-override \
  reuse-build-failures \
  reuse-build-timeouts \
  keep-builds-running
do
  val="$(printenv INPUTS_JSON | jq -r ".\"$setting\"")"
  if [ -n "$val" ] && [ "$val" != "null" ]; then
    add_env "NIXBUILDNET_$(echo "$setting" | tr a-z- A-Z_)" "$val"
  fi
done


# Propagate selected GitHub Actions environment variables as nixbuild.net tags
# https://docs.github.com/en/actions/reference/environment-variables#default-environment-variables
for tag in \
  GITHUB_ACTOR \
  GITHUB_JOB \
  GITHUB_REF \
  GITHUB_REPOSITORY \
  GITHUB_RUN_ATTEMPT \
  GITHUB_RUN_ID \
  GITHUB_RUN_NUMBER \
  GITHUB_SHA \
  GITHUB_WORKFLOW
do
  add_env "NIXBUILDNET_TAG_$tag" "$(printenv $tag)"
done
add_env "NIXBUILDNET_TAG_GITHUB_INVOCATION_ID" "$(basename "$INVOCATION_ID")"


# Write ssh env to config
echo "SetEnv$nixbuildnet_env" >> "$SSH_CONFIG_FILE"


# Append ssh config to system config
sudo mkdir -p /etc/ssh
sudo touch /etc/ssh/ssh_config
sudo tee -a /etc/ssh/ssh_config < "$SSH_CONFIG_FILE" >/dev/null


# Setup Nix builders
NIX_BUILDERS_FILE="$(mktemp)"
cat >"$NIX_BUILDERS_FILE" <<EOF
eu.nixbuild.net x86_64-linux - 200 1 big-parallel,benchmark,kvm,nixos-test
eu.nixbuild.net aarch64-linux - 200 1 big-parallel,benchmark
EOF


# Setup nix config (TODO: proper parser)
NIXOS_CACHE="http://cache.nixos.org"
NIXOS_CACHE_PUBKEY="cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
NIXBUILD_CACHE="ssh://eu.nixbuild.net?priority=100"
NIXBUILD_CACHE_PUBKEY="$(ssh eu.nixbuild.net api show public-signing-key | jq -r '"\(.keyName):\(.publicKey)"')"

NIX_CONF_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/nix/nix.conf"
mkdir -p "$(dirname "$NIX_CONF_FILE")"
touch "$NIX_CONF_FILE"

prev_substituters="$(echo "substituters = $NIXOS_CACHE" | cat "$NIX_CONF_FILE" - | egrep -m1 '^substituters =')"
substituters="$prev_substituters $NIXBUILD_CACHE"

prev_public_keys="$(echo "trusted-public-keys = $NIXOS_CACHE_PUBKEY" | cat "$NIX_CONF_FILE" - | egrep -m1 '^trusted-public-keys =')"
public_keys="$prev_public_keys $NIXBUILD_CACHE_PUBKEY"

egrep -v "substituters =|trusted-public-keys =" "$NIX_CONF_FILE" >"$NIX_CONF_FILE.tmp" || true

cat >>"$NIX_CONF_FILE.tmp" <<EOF
$substituters
$public_keys
max-jobs = 0
builders = @$NIX_BUILDERS_FILE
builders-use-substitutes = true
require-sigs = true
EOF

mv "$NIX_CONF_FILE.tmp" "$NIX_CONF_FILE"
