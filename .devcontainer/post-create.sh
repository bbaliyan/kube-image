#!/usr/bin/env bash
# post-create.sh — runs once when the devcontainer is first created.
# Installs the org root CA into the system trust store.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORG_CA_SRC="${SCRIPT_DIR}/org-root-ca.pem"

echo "==> Installing org root CA..."

if [[ ! -f "${ORG_CA_SRC}" ]]; then
  echo "ERROR: org-root-ca.pem not found at ${ORG_CA_SRC}"
  echo "       Add the org root CA PEM file before building the container."
  exit 1
fi

CA_SUBJECT="$(openssl x509 -noout -subject -in "${ORG_CA_SRC}" | sed 's/subject=//')"
CA_ISSUER="$(openssl x509 -noout -issuer  -in "${ORG_CA_SRC}" | sed 's/issuer=//')"

if [[ "${CA_SUBJECT}" != "${CA_ISSUER}" ]]; then
  echo "ERROR: org-root-ca.pem is not self-issued (not a root CA)."
  echo "  subject: ${CA_SUBJECT}"
  echo "  issuer:  ${CA_ISSUER}"
  exit 1
fi

cp "${ORG_CA_SRC}" /usr/local/share/ca-certificates/org-root-ca.crt
update-ca-certificates --fresh >/dev/null
echo "    Org root CA installed."
