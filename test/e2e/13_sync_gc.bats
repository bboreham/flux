#!/usr/bin/env bats

load lib/env
load lib/install
load lib/poll
load lib/defer

git_port_forward_pid=""

function setup() {
  kubectl create namespace "$FLUX_NAMESPACE"
  # Install flux and the git server, allowing external access
  install_git_srv flux-git-deploy git_srv_result
  # shellcheck disable=SC2154
  git_ssh_cmd="${git_srv_result[0]}"
  export GIT_SSH_COMMAND="$git_ssh_cmd"
  # shellcheck disable=SC2154
  git_port_forward_pid="${git_srv_result[1]}"
  install_flux_with_fluxctl "13_sync_gc"
}

@test "Sync with garbage collection test" {
  # Wait until flux deploys the workloads, which indicates it has at least started a sync
  poll_until_true 'workload podinfo' 'kubectl -n demo describe deployment/podinfo'

  # make sure we have _finished_ a sync run
  fluxctl --k8s-fwd-ns "${FLUX_NAMESPACE}" sync

  # Clone the repo and check the sync tag
  local clone_dir
  clone_dir="$(mktemp -d)"
  defer rm -rf "$clone_dir"
  git clone -b master ssh://git@localhost/git-server/repos/cluster.git "$clone_dir"
  cd "$clone_dir"
  local sync_tag_hash
  sync_tag_hash=$(git rev-list -n 1 flux)
  head_hash=$(git rev-list -n 1 HEAD)
  [ "$sync_tag_hash" = "$head_hash" ]

  # Remove a manifest and commit that
  git rm workloads/podinfo-dep.yaml
  git -c 'user.email=foo@bar.com' -c 'user.name=Foo' commit -m "Remove podinfo deployment"
  head_hash=$(git rev-list -n 1 HEAD)
  git push >&3

  fluxctl --k8s-fwd-ns "${FLUX_NAMESPACE}" sync

  poll_until_equals "podinfo deployment removed" "[]" "kubectl get deploy -n demo -o\"jsonpath={['items']}\""
  git pull -f --tags >&3
  sync_tag_hash=$(git rev-list -n 1 flux)
  [ "$sync_tag_hash" = "$head_hash" ]
}

function teardown() {
  kill "$git_port_forward_pid"
  # Removing the namespace also takes care of removing Flux and gitsrv.
  kubectl delete namespace "$FLUX_NAMESPACE"
  # Only remove the demo workloads after Flux, so that they cannot be recreated.
  kubectl delete namespace "$DEMO_NAMESPACE"
}
