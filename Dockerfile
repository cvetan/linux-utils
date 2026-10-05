# syntax=docker/dockerfile:1
# =============================================================================
# Dockerfile — a disposable sandbox to run main.sh against a clean Ubuntu
# =============================================================================
# This builds only the sandbox, not the repository: a bare Ubuntu, a non-root
# `tester` with passwordless sudo, and a policy-rc.d so apt maintainer scripts
# cannot try to start services in a container that has no init. The repository
# is NOT copied in — scripts/docker-test.sh mounts it read-only at /work, so the
# same image always runs the current working tree and every `docker run --rm`
# starts from a pristine filesystem.
#
#   docker build --build-arg UBUNTU_VERSION=26.04 -t linux-utils-test:26.04 .
#   docker run --rm -v "$PWD:/work:ro" linux-utils-test:26.04
#
# or, for a whole release at once:
#
#   scripts/docker-test.sh 26.04

# The release under test. 26.04 is the current LTS and the primary target; older
# LTSes (22.04, 24.04) build from the same file and are exercised by
# scripts/docker-test.sh.
ARG UBUNTU_VERSION=26.04
FROM ubuntu:${UBUNTU_VERSION}

# Unattended: preflight auto-approves without a TTY, and sudo never prompts
# (there is no TTY to prompt on).
ENV DEBIAN_FRONTEND=noninteractive \
    SETUP_ASSUME_YES=1

# Deliberately minimal. curl and software-properties-common are NOT installed,
# so the run exercises base_packages.sh's own bootstrap instead of being handed
# them. Only sudo — needed to host the tester user — is pre-seeded.
# hadolint ignore=DL3008
RUN apt update \
    && apt install -y --no-install-recommends sudo \
    && rm -rf /var/lib/apt/lists/*

# A container has no init. Without this, a maintainer script that calls
# invoke-rc.d (docker-ce's postinst, for one) fails and takes the apt run with
# it. exit 101 tells invoke-rc.d "do not start anything".
RUN printf '#!/bin/sh\nexit 101\n' > /etc/policy-rc.d \
    && chmod +x /etc/policy-rc.d

# A normal user with passwordless sudo, closer to a real desktop than root.
RUN useradd -m -s /bin/bash tester \
    && printf 'tester ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/tester \
    && chmod 0440 /etc/sudoers.d/tester

USER tester
WORKDIR /work

# The repository is bind-mounted here by scripts/docker-test.sh. Invoked through
# `bash` so a mount that lost the executable bit still runs.
CMD ["bash", "./main.sh"]
