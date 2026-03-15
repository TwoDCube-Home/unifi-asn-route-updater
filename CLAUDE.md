# UniFi ASN Route Updater

## Project Setup

- Shell script that updates UniFi policy-based routes with IP prefixes from ASN lookups
- Uses the UniFi Site Manager Cloud Connector API (api.ui.com)
- Dependencies: curl, jq, aggregate6, python3
- Built as a container image via `Containerfile` (UBI9-based)
- CI/CD via GitHub Actions in `.github/workflows/`

## Release Process

1. **Make changes** to `ui-update-asn-routes.sh` (or other files)
2. **Verify locally**: `shellcheck ui-update-asn-routes.sh` (if available)
3. **Commit and push** to `main`
4. **Wait for CD** (`build.yaml`): builds the container image and pushes to `ghcr.io/twodcube-home/unifi-asn-route-updater` with tags `latest` and the commit SHA
5. **Get the image tag from the CD logs** — do NOT use `git rev-parse HEAD` locally, as it can differ from the SHA GitHub Actions checks out. Check the "Push image" step for the actual tag.
6. **Update ArgoCD**: edit the deployment manifest in the `TwoDCube-Home/argocd` repo — set the image tag to the SHA from the CD logs
7. **Push ArgoCD repo** — ArgoCD picks up the change and rolls out the new deployment

## Key Paths

- ArgoCD repo: `TwoDCube-Home/argocd` on GitHub
- Image: `ghcr.io/twodcube-home/unifi-asn-route-updater:<commit-sha>`
