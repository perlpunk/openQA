FROM docker.io/opensuse/leap:15.6

RUN zypper ar -f -p 95 http://download.opensuse.org/repositories/devel:openQA/15.6 devel_openQA && \
    zypper --gpg-auto-import-keys ref && \
    zypper in -y git openQA-single-instance openQA-bootstrap \
    qemu-arm qemu-ppc qemu-x86 qemu-tools sudo iputils os-autoinst-distri-opensuse-deps && \
    zypper clean -a

ENV skip_suse_specifics=1
ENV skip_suse_tests=1
ENV VNCPORT_OFFSET=100
