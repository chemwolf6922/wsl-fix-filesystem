FROM alpine:3.20

RUN apk add --no-cache e2fsprogs util-linux

RUN echo "wsl-fix-filesystem helper distro" > /etc/wsl-fixer-release

CMD ["/bin/sh"]
