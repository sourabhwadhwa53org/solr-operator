#!/usr/bin/env bash
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# exit immediately when a command fails
set -e
# only exit with zero if all commands of the pipeline exit successfully
set -o pipefail
# error on unset variables
set -u

show_help() {
cat << EOF
Usage: ./hack/release/smoke_test/test_cluster.sh [-h] [-i IMAGE] [-k KUBERNETES_VERSION] [-t SOLR_VERSION] -v VERSION -l LOCATION -g GPG_KEY

Test the release candidate in a Kind cluster

    -h  Display this help and exit
    -v  Version of the Solr Operator
    -i  Solr Operator docker image to use  (Optional, defaults to apache/solr-operator:<version>)
    -l  Base location of the staged artifacts. Can be a URL or relative or absolute file path.
    -g  GPG Key (fingerprint) used to sign the artifacts
    -k  Kubernetes Version to test with (full tag, e.g. v1.21.2)
    -t  Solr Version, or image, to test with (full tag, e.g. 8.10.0)
EOF
}

OPTIND=1
while getopts hv:i:l:g:k:t: opt; do
    case $opt in
        h)
            show_help
            exit 0
            ;;
        v)  VERSION=$OPTARG
            ;;
        i)  IMAGE=$OPTARG
            ;;
        l)  LOCATION=$OPTARG
            ;;
        g)  GPG_KEY=$OPTARG
            ;;
        k)  KUBERNETES_VERSION=$OPTARG
            ;;
        t)  SOLR_VERSION=$OPTARG
            ;;
        *)
            show_help >&2
            exit 1
            ;;
    esac
done
shift "$((OPTIND-1))"   # Discard the options and sentinel --

if [[ -z "${VERSION:-}" ]]; then
  echo "Specify a project version through -v, or through the VERSION env var" >&2 && exit 1
fi
if [[ -z "${IMAGE:-}" ]]; then
  IMAGE="apache/solr-operator:${VERSION}"
fi
if [[ -z "${LOCATION:-}" ]]; then
  echo "Specify an base artifact location -l, or through the LOCATION env var" >&2 && exit 1
fi
if [[ -z "${GPG_KEY:-}" ]]; then
  echo "Specify a gpg key fingerprint through -g, or through the GPG_KEY env var" >&2 && exit 1
fi
if [[ -z "${KUBERNETES_VERSION:-}" ]]; then
  KUBERNETES_VERSION="v1.21.2"
fi
if [[ -z "${SOLR_VERSION:-}" ]]; then
  SOLR_VERSION="8.10.0"
fi

# If LOCATION is not a URL, then get the absolute path
if ! (echo "${LOCATION}" | grep "http"); then
  LOCATION=$(cd "${LOCATION}"; pwd)
  LOCATION=${LOCATION%%/}

  OP_HELM_CHART="${LOCATION}/helm-charts/solr-operator-${VERSION#v}.tgz"
  SOLR_HELM_CHART="${LOCATION}/helm-charts/solr-${VERSION#v}.tgz"
else
  # If LOCATION is a URL, then we want to make sure we have the up-to-date docker image.
  docker pull "${IMAGE}"

  # Add the Test Helm Repo
  helm repo add --force-update "apache-solr-test-${VERSION}" "${LOCATION}/helm-charts"

  OP_HELM_CHART="apache-solr-test-${VERSION}/solr-operator"
  SOLR_HELM_CHART="apache-solr-test-${VERSION}/solr"
fi

if ! (which kind); then
  echo "Install Kind (Kubernetes in Docker)"
  GO111MODULE="on" go install sigs.k8s.io/kind@v0.11.1
fi

CLUSTER_NAME="solr-operator-${VERSION}-rc"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"

if (kind get clusters | grep "${CLUSTER_NAME}"); then
  printf "Delete cluster, so the test starts with a clean slate.\n\n"
  kind delete clusters "${CLUSTER_NAME}"
fi

echo "Create test Kubernetes ${KUBERNETES_VERSION} cluster in Kind. This will allow us to test the CRDs, Helm chart and the Docker image."
kind create cluster --name "${CLUSTER_NAME}" --image "kindest/node:${KUBERNETES_VERSION}"

# Load the docker image into the cluster
kind load docker-image --name "${CLUSTER_NAME}" "${IMAGE}"

# Add a temporary directory for backups
docker exec "${CLUSTER_NAME}-control-plane" bash -c "mkdir -p /tmp/backup"

echo "Import Solr Keys"
curl -sL0 "https://dist.apache.org/repos/dist/release/solr/KEYS" | gpg --import --quiet

# First generate the old-style public key ring, if it doesn't already exist and contain the information we want
if ! (gpg --no-default-keyring --keyring=~/.gnupg/pubring.gpg --list-keys "${GPG_KEY}"); then
  gpg --export >~/.gnupg/pubring.gpg
fi

# Install the Solr Operator
kubectl create -f "${LOCATION}/crds/all-with-dependencies.yaml" || kubectl replace -f "${LOCATION}/crds/all-with-dependencies.yaml"
helm install --kube-context "${KUBE_CONTEXT}" --verify solr-operator "${OP_HELM_CHART}" --set image.tag="${IMAGE##*:}" \
    --set image.repository="${IMAGE%%:*}" \
    --set image.pullPolicy="Never"

printf "\nInstall a test Solr Cluster\n"
helm install --kube-context "${KUBE_CONTEXT}" --verify example "${SOLR_HELM_CHART}" \
    --set replicas=3 \
    --set image.tag=${SOLR_VERSION} \
    --set solrJavaMem="-Xms1g -Xmx3g" \
    --set customSolrKubeOptions.podOptions.resources.limits.memory="1G" \
    --set customSolrKubeOptions.podOptions.resources.requests.cpu="300m" \
    --set customSolrKubeOptions.podOptions.resources.requests.memory="512Mi" \
    --set zookeeperRef.provided.persistence.spec.resources.requests.storage="5Gi" \
    --set zookeeperRef.provided.replicas=1 \
    --set "backupRepositories[0].name=local" \
    --set "backupRepositories[0].volume.source.hostPath.path=/tmp/backup"

# If LOCATION is a URL, then remove the helm repo after use
if (echo "${LOCATION}" | grep "http"); then
  helm repo remove "apache-solr-test-${VERSION}"
fi

# Wait for solrcloud to be ready
printf '\nWait for all 3 Solr nodes to become ready.\n\n'
grep -q "3              3       3            3" <(exec kubectl get solrcloud example -w); kill $!

# Expose the common Solr service to localhost
kubectl port-forward service/example-solrcloud-common 18983:80 || true &
sleep 2

printf "\nCheck the admin URL to make sure it works\n"
curl --silent "http://localhost:18983/solr/admin/info/system" | grep '"status":0' > /dev/null

printf "\nCreating a test collection\n"
curl --silent "http://localhost:18983/solr/admin/collections?action=CREATE&name=smoke-test&replicationFactor=2&numShards=1" | grep '"status":0' > /dev/null

printf "\nQuery the test collection, test for 0 docs\n"
curl --silent "http://localhost:18983/solr/smoke-test/select" | grep '\"numFound\":0' > /dev/null

printf "\nCreate a Solr Backup to take local backups of the test collection\n"
cat <<EOF | kubectl apply -f -
apiVersion: solr.apache.org/v1beta1
kind: SolrBackup
metadata:
  name: ex-back
spec:
  solrCloud: example
  collections:
    - smoke-test
  location: test-dir/
  repositoryName: local
  recurrence:
    schedule: "@every 10s"
    maxSaved: 3
EOF

printf "\nCreate a Solr Prometheus Exporter to expose metrics for the Solr Cloud\n"
cat <<EOF | kubectl apply -f -
apiVersion: solr.apache.org/v1beta1
kind: SolrPrometheusExporter
metadata:
  name: example
spec:
  solrReference:
    cloud:
      name: "example"
  numThreads: 4
  image:
    tag: 8.7.0
EOF

printf "\nWait for the Solr Prometheus Exporter to be ready\n"
sleep 5
kubectl rollout status deployment/example-solr-metrics

# Expose the Solr Prometheus Exporter service to localhost
kubectl port-forward service/example-solr-metrics 18984:80 || true &
sleep 15

printf "\nQuery the prometheus exporter, test for 'http://example-solrcloud-*.example-solrcloud-headless.default:8983/solr' (internal) URL being scraped.\n"
curl --silent "http://localhost:18984/metrics" | grep 'http://example-solrcloud-.*.example-solrcloud-headless.default:8983/solr' > /dev/null

printf "\nWait 20 seconds, so that more backups can be taken.\n"
sleep 20

printf "\nList the backups, and make sure that >= 3 have been taken (should be four), but only 3 are saved.\n"
BACKUP_RESP=$(curl --silent -L "http://localhost:18983/solr/admin/collections?action=LISTBACKUP&name=ex-back-smoke-test&repository=local&collection=smoke-test&location=/var/solr/data/backup-restore/local/test-dir")
SAVED_BACKUPS=$(echo "${BACKUP_RESP}" | jq --raw-output '.backups | length')
if [[ "${SAVED_BACKUPS}" != "3" ]]; then
    echo "Wrong number of saved backups, should be 3, found ${SAVED_BACKUPS}" >&2
    exit 1
fi
LAST_BACKUP_ID=$(echo "${BACKUP_RESP}" | jq --raw-output '.backups[-1].backupId')
if (( "${LAST_BACKUP_ID}" < 4 )); then
    echo "The last backup id must be > 3, since we should have taken at least 4 backups. Last backup id found: ${LAST_BACKUP_ID}" >&2
    exit 1
fi

printf "\nStop recurring backup\n"
cat <<EOF | kubectl apply -f -
apiVersion: solr.apache.org/v1beta1
kind: SolrBackup
metadata:
  name: ex-back
spec:
  solrCloud: example
  collections:
    - smoke-test
  location: test-dir/
  repositoryName: local
  recurrence:
    schedule: "@every 10s"
    maxSaved: 3
    disabled: true
EOF
sleep 5
LAST_BACKUP_ID=$(curl --silent -L "http://localhost:18983/solr/admin/collections?action=LISTBACKUP&name=ex-back-smoke-test&repository=local&collection=smoke-test&location=/var/solr/data/backup-restore/local/test-dir" | jq --raw-output '.backups[-1].backupId')

printf "\nWait to make sure more backups are not taken\n"
sleep 15
FOUND_BACKUP_ID=$(curl --silent -L "http://localhost:18983/solr/admin/collections?action=LISTBACKUP&name=ex-back-smoke-test&repository=local&collection=smoke-test&location=/var/solr/data/backup-restore/local/test-dir" | jq --raw-output '.backups[-1].backupId')
if (( "${FOUND_BACKUP_ID}" != "${LAST_BACKUP_ID}" )); then
    echo "The another backup has been taken since recurrence was stopped. Last backupId should be '${LAST_BACKUP_ID}', but instead found '${FOUND_BACKUP_ID}'." >&2
    exit 1
fi

echo "Delete test Kind Kubernetes cluster."
kind delete clusters "${CLUSTER_NAME}"

printf "\n********************\nLocal end-to-end cluster test successfully run!\n\n"
