# Image Mode GitLab build bundle

This bundle builds an OCI bootc image containing RHEL 10 Image Mode and GitLab EE.

## Files

- `build-gitlab-image-mode.yml`: Ansible build and optional push workflow.
- `templates/Containerfile.j2`: Adds the GitLab RPM repository, installs GitLab,
  installs the first-boot script, and enables its systemd unit.
- `files/gitlab-firstboot.sh`: The supplied first-boot configuration script.
- `templates/gitlab-firstboot.service.j2`: Runs configuration once after
  cloud-init and networking.
- `templates/99-gitlab-image-mode.cfg.j2`: cloud-init drop-in.
- `templates/gitlab-firstboot.env.example.j2`: deployment variables example.

## Install collection

```bash
ansible-galaxy collection install -r requirements.yml
```

## Build locally on the image-builder host

```bash
ansible-playbook -i inventory.example \
  build-gitlab-image-mode.yml \
  -e gitlab_image_registry=quay-1.example.com \
  -e gitlab_image_namespace=image-mode \
  -e gitlab_image_tag=latest
```

## Build and push

Supply the password through AAP, Vault, or another secret integration:

```bash
ansible-playbook -i inventory.example \
  build-gitlab-image-mode.yml \
  -e gitlab_image_registry=quay-1.example.com \
  -e gitlab_image_namespace=image-mode \
  -e gitlab_push_image=true \
  -e gitlab_registry_username=image-mode-builder \
  -e gitlab_registry_password='REDACTED'
```

## Satellite/cloud-init requirement

Provision `/etc/gitlab-firstboot.env` before `gitlab-firstboot.service` runs.
The service has `ConditionPathExists=/etc/gitlab-firstboot.env`, so it will not
run without deployment-specific settings.

A cloud-init user-data example:

```yaml
#cloud-config
write_files:
  - path: /etc/gitlab-firstboot.env
    owner: root:root
    permissions: '0600'
    content: |
      GITLAB_EXTERNAL_URL=https://gitlab.example.com
      GITLAB_TIMEZONE=America/New_York
      GITLAB_ENABLE_LETSENCRYPT=false
runcmd:
  - [systemctl, start, gitlab-firstboot.service]
```

## Important

The GitLab repository must publish a package compatible with the selected RHEL
release and architecture. Pin `gitlab_package_version` for reproducible builds.
For disconnected builds, replace the repository setup step with your mirrored
RPM repository or a staged RPM.
