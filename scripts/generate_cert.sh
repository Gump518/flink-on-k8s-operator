#!/bin/bash

set -exo pipefail

usage() {
  cat << EOF
Generate certificate for admission webhook service. This script uses
k8s' CertificateSigningRequest API to a generate a certificate signed
by k8s CA for admission webhook services. This requires permissions
to create and approve CSR. See
https://kubernetes.io/docs/tasks/tls/managing-tls-in-a-cluster for
detailed explantion and additional instructions.
The server key/cert k8s CA cert are stored in a k8s secret.

Usage: ${0} [OPTIONS]
The following flags are required.
--service          Service name of webhook.
--namespace        Namespace where webhook service and secret reside.
--secret           Secret name for CA certificate and server certificate/key pair.
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case ${1} in
    --service)
      shift
      service="${1}"
      ;;
    --secret)
      shift
      secret="${1}"
      ;;
    -n | --namespace)
      shift
      namespace="${1}"
      ;;
    *)
      usage
      ;;
  esac
  shift
done

if [[ -z ${service} ]]; then
  echo "service argument is not provided."
  exit 1
fi

if [[ -z ${secret} ]]; then
  echo "secret argument is not provided."
  exit 1
fi

if [[ -z ${namespace} ]]; then
  echo "namespace argument is not provided."
  exit 1
fi

if kubectl get secret "${secret}" -n "${namespace}" 1> /dev/null 2>&1; then
  echo "Secret ${secret} already exists."
  exit 0
fi

# Create the namespace to store cert in
if ! kubectl get namespace "${namespace}" 1> /dev/null 2>&1; then
  kubectl create namespace "${namespace}"
fi

if [[ ! -x "$(command -v openssl)" ]]; then
  echo "openssl not found"
  exit 1
fi

csrName=${service}.${namespace}
tmpdir=$(mktemp -d)
echo "creating certs in tmpdir ${tmpdir} "

cat << EOF > ${tmpdir}/csr.conf
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = ${service}
DNS.2 = ${service}.${namespace}
DNS.3 = ${service}.${namespace}.svc
EOF

openssl genrsa -out ${tmpdir}/server-key.pem 2048
openssl req -new -key ${tmpdir}/server-key.pem -subj "/CN=${service}.${namespace}.svc" -out ${tmpdir}/server.csr -config ${tmpdir}/csr.conf

# clean-up any previously created CSR for our service. Ignore errors if not present.
kubectl delete csr ${csrName} 2> /dev/null || true

# create  server cert/key CSR and send to k8s API
cat << EOF | kubectl create -f -
apiVersion: certificates.k8s.io/v1beta1
kind: CertificateSigningRequest
metadata:
  name: ${csrName}
spec:
  groups:
  - system:authenticated
  request: $(cat ${tmpdir}/server.csr | base64 | tr -d '\n')
  usages:
  - digital signature
  - key encipherment
  - server auth
EOF

# verify CSR has been created
while true; do
  kubectl get csr ${csrName}
  if [ "$?" -eq 0 ]; then
    break
  fi
  sleep 1
done

# approve and fetch the signed certificate
kubectl certificate approve ${csrName}

# verify certificate has been signed
for x in $(seq 10); do
  serverCert=$(kubectl get csr ${csrName} -o jsonpath='{.status.conditions[0].status}')
  if [[ ${serverCert} == 'True' ]]; then
    break
  fi
  sleep 1
done
if [[ ${serverCert} == '' ]]; then
  echo "ERROR: After approving csr ${csrName}, the signed certificate did not appear on the resource. Giving up after 10 attempts." >&2
  exit 1
fi
echo ${serverCert} | openssl base64 -d -A -out ${tmpdir}/server-cert.crt

# create the secret with CA cert and server cert/key
kubectl create secret generic ${secret} \
  -n ${namespace} \
  --from-file=tls.key=${tmpdir}/server-key.pem \
  --from-file=tls.crt=${tmpdir}/server-cert.crt \
  --dry-run -o yaml |
  kubectl apply -f -
